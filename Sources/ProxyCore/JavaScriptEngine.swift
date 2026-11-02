#if canImport(JavaScriptCore)
import Foundation
import JavaScriptCore

/// Runs user scripts in JavaScriptCore. Each script gets its own context (so their top-level names
/// never clash) on one virtual machine, and every call runs on one serial queue.
///
/// A call that runs longer than `timeLimit` is stopped by JavaScriptCore's watchdog and its script
/// starts over on the next call. If the watchdog isn't available, the caller still gets an answer
/// after the limit, and the engine refuses further calls until it is replaced (by editing a script).
public final class JavaScriptEngine: ScriptEngine, @unchecked Sendable {
    public static let defaultTimeLimit: TimeInterval = 1

    public let timeLimit: TimeInterval
    private let queue = DispatchQueue(label: "app.wiretide.scripts", qos: .userInitiated)
    private let lock = NSLock()
    private var isStuck = false

    // Confined to `queue`.
    private var machine: JSVirtualMachine?
    private var contexts: [UUID: JSContext] = [:]
    /// Scripts that failed to load, with the source that failed, so the error is reported once per edit.
    private var loadFailures: [UUID: String] = [:]

    public init(scripts: [UserScript] = [], timeLimit: TimeInterval = defaultTimeLimit) {
        self.timeLimit = timeLimit
        // Load the scripts ahead of the first request, so their top level has run by then.
        queue.async { [self] in
            for script in scripts { _ = try? context(for: script) }
        }
    }

    public func call(_ hook: ScriptHook, script: UserScript, input: String) -> ScriptCallResult {
        // Paused after a call never came back; the failure was already reported.
        if lock.withLock({ isStuck }) { return .output(#"{"skipped":true}"#) }

        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            box.value = perform(hook, script: script, input: input)
            done.signal()
        }
        // The watchdog stops a runaway script after `timeLimit`; this is the backstop.
        if done.wait(timeout: .now() + timeLimit + 2) == .timedOut {
            lock.withLock { isStuck = true }
            return .failure("\(hook.functionName) didn't finish within \(Self.seconds(timeLimit)); scripts are paused until you edit one",
                            line: nil)
        }
        return box.value ?? .failure("The script engine returned nothing", line: nil)
    }

    private final class ResultBox: @unchecked Sendable {
        var value: ScriptCallResult?
    }

    // MARK: On the queue

    private func perform(_ hook: ScriptHook, script: UserScript, input: String) -> ScriptCallResult {
        let context: JSContext
        do {
            context = try self.context(for: script)
        } catch let error as LoadError {
            if loadFailures[script.id] == script.source { return .output(#"{"skipped":true}"#) }
            loadFailures[script.id] = script.source
            return .failure(error.message, line: error.line)
        } catch {
            return .failure(String(describing: error), line: nil)
        }
        guard let function = context.objectForKeyedSubscript("__wiretide")?.objectForKeyedSubscript(hook.rawValue),
              function.isObject else {
            return .failure("The script runtime is missing", line: nil)
        }
        context.exception = nil
        let started = Date()
        let value = function.call(withArguments: [input])
        if let exception = context.exception {
            // Only the watchdog gets here: the runtime catches the script's own errors.
            contexts[script.id] = nil
            if Date().timeIntervalSince(started) >= timeLimit * 0.9 {
                return .failure("\(hook.functionName) was stopped after \(Self.seconds(timeLimit)); the script starts over on the next call",
                                line: nil)
            }
            return .failure(Self.describe(exception), line: Self.line(of: exception))
        }
        guard let value, value.isString, let text = value.toString() else {
            return .failure("The script runtime returned nothing", line: nil)
        }
        return .output(text)
    }

    private struct LoadError: Error {
        var message: String
        var line: Int?
    }

    /// The script's context, made (and the script run from the top) on first use.
    private func context(for script: UserScript) throws -> JSContext {
        if let context = contexts[script.id] { return context }
        if machine == nil { machine = JSVirtualMachine() }
        guard let machine, let context = JSContext(virtualMachine: machine) else {
            throw LoadError(message: "JavaScriptCore couldn't create a context", line: nil)
        }
        context.name = script.displayName
        Self.applyTimeLimit(timeLimit, to: context)
        context.evaluateScript(ScriptPrelude.source, withSourceURL: URL(string: "wiretide://runtime.js"))
        if let exception = context.exception {
            throw LoadError(message: "The script runtime failed to load: \(Self.describe(exception))", line: nil)
        }
        let started = Date()
        context.evaluateScript(script.source, withSourceURL: URL(string: "wiretide://script.js"))
        if let exception = context.exception {
            if Date().timeIntervalSince(started) >= timeLimit * 0.9 {
                throw LoadError(message: "The script's top level was stopped after \(Self.seconds(timeLimit))", line: nil)
            }
            throw LoadError(message: Self.describe(exception), line: Self.line(of: exception))
        }
        loadFailures[script.id] = nil
        contexts[script.id] = context
        return context
    }

    // MARK: Helpers

    static func describe(_ exception: JSValue) -> String {
        exception.toString() ?? "Unknown error"
    }

    static func line(of exception: JSValue) -> Int? {
        guard let line = exception.objectForKeyedSubscript("line"), line.isNumber else { return nil }
        return Int(line.toInt32())
    }

    /// "1 second", "0.5 seconds".
    public static func seconds(_ interval: TimeInterval) -> String {
        interval == 1 ? "1 second" : "\(interval.formatted()) seconds"
    }

    /// `JSContextGroupSetExecutionTimeLimit` stops a script that runs too long. It isn't in the public
    /// headers, so it is looked up at run time; without it, `call` falls back to its own timeout.
    private typealias SetExecutionTimeLimit = @convention(c) (
        JSContextGroupRef?, Double, (@convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool)?, UnsafeMutableRawPointer?
    ) -> Void

    private static let setExecutionTimeLimit: SetExecutionTimeLimit? = {
        // RTLD_DEFAULT
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit") else { return nil }
        return unsafeBitCast(symbol, to: SetExecutionTimeLimit.self)
    }()

    /// Whether runaway scripts can be stopped (rather than only abandoned).
    public static var canStopRunawayScripts: Bool { setExecutionTimeLimit != nil }

    private static func applyTimeLimit(_ limit: TimeInterval, to context: JSContext) {
        guard let setExecutionTimeLimit, let global = context.jsGlobalContextRef else { return }
        setExecutionTimeLimit(JSContextGetGroup(global), limit, nil, nil)
    }
}

/// Syntax checking for the script editor: compiles without running anything.
public enum ScriptSyntax {
    public struct Problem: Equatable, Sendable {
        public var message: String
        public var line: Int?
    }

    /// The first syntax error in `source`, or nil when it compiles.
    /// Reused between checks; only compiled into, never run.
    private static let context: JSContext? = JSContext()

    public static func check(_ source: String) -> Problem? {
        guard let context, let global = context.jsGlobalContextRef else { return nil }
        let script = JSStringCreateWithCFString(source as CFString)
        defer { JSStringRelease(script) }
        var exception: JSValueRef?
        guard !JSCheckScriptSyntax(global, script, nil, 1, &exception) else { return nil }
        guard let exception, let value = JSValue(jsValueRef: exception, in: context) else {
            return Problem(message: "Syntax error", line: nil)
        }
        return Problem(message: JavaScriptEngine.describe(value), line: JavaScriptEngine.line(of: value))
    }
}
#endif
