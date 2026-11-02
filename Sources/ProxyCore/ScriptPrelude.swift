// The JavaScript every script context loads before the script itself. Kept in Swift so the
// package has no resources; `Tests/ProxyCoreTests/ScriptingTests` exercise it through JavaScriptCore.
//
// Swift calls `__wiretide.request/response/publish` with the JSON that `ScriptRunner` encodes and
// gets JSON back: what the script changed, what it logged, and any error.
enum ScriptPrelude {
    static let source = #"""
// Wiretide script runtime. Evaluated in each script's context before the script itself.
// Swift calls __wiretide.request/response/publish with a JSON string and gets a JSON string back.
(function (global) {
  "use strict";
  var logs = [];

  function show(value) {
    if (typeof value === "string") return value;
    if (value === undefined) return "undefined";
    if (value instanceof Error) return value.name + ": " + value.message;
    try {
      var text = JSON.stringify(value, null, 2);
      return text === undefined ? String(value) : text;
    } catch (e) {
      return String(value);
    }
  }
  function logger(level) {
    return function () {
      var parts = [];
      for (var i = 0; i < arguments.length; i++) parts.push(show(arguments[i]));
      if (logs.length < 200) logs.push([level, parts.join(" ")]);
    };
  }
  global.console = { log: logger("log"), info: logger("log"), debug: logger("log"), warn: logger("warn"), error: logger("error") };

  // Headers: a case-insensitive object. Reading `headers["content-type"]` finds "Content-Type";
  // setting a name that exists replaces it in place; `delete` removes every copy. Repeated headers
  // read as an array, and an array value writes one header per element.
  function makeHeaders(pairs) {
    var entries = pairs.map(function (p) { return [p[0], p[1]]; });
    function find(name) {
      var lower = String(name).toLowerCase();
      return entries.filter(function (e) { return e[0].toLowerCase() === lower; });
    }
    var target = {};
    var proxy = new Proxy(target, {
      get: function (t, name) {
        if (typeof name !== "string") return undefined;
        if (name === "toJSON") return function () { return toObject(); };
        var found = find(name);
        if (found.length === 0) return undefined;
        return found.length === 1 ? found[0][1] : found.map(function (e) { return e[1]; });
      },
      set: function (t, name, value) {
        var lower = String(name).toLowerCase();
        var values = Array.isArray(value) ? value.map(String) : [String(value)];
        var first = -1;
        for (var i = 0; i < entries.length; i++) {
          if (entries[i][0].toLowerCase() === lower) { first = i; break; }
        }
        var spelled = first >= 0 ? entries[first][0] : String(name);
        entries = entries.filter(function (e) { return e[0].toLowerCase() !== lower; });
        var added = values.map(function (v) { return [spelled, v]; });
        if (first < 0 || first > entries.length) first = entries.length;
        entries.splice.apply(entries, [first, 0].concat(added));
        return true;
      },
      deleteProperty: function (t, name) {
        var lower = String(name).toLowerCase();
        entries = entries.filter(function (e) { return e[0].toLowerCase() !== lower; });
        return true;
      },
      has: function (t, name) { return find(name).length > 0; },
      ownKeys: function () {
        var seen = {};
        var keys = [];
        entries.forEach(function (e) {
          var lower = e[0].toLowerCase();
          if (!seen[lower]) { seen[lower] = true; keys.push(e[0]); }
        });
        return keys;
      },
      getOwnPropertyDescriptor: function (t, name) {
        var found = find(name);
        if (found.length === 0) return undefined;
        return { value: proxy[name], writable: true, enumerable: true, configurable: true };
      }
    });
    function toObject() {
      var object = {};
      Object.keys(proxy).forEach(function (k) { object[k] = proxy[k]; });
      return object;
    }
    return { proxy: proxy, pairs: function () { return entries.map(function (e) { return [e[0], e[1]]; }); } };
  }

  // Turns whatever the script left in `headers` back into name/value pairs.
  function headerPairs(value, made) {
    if (value === made.proxy) return made.pairs();
    var pairs = [];
    if (Array.isArray(value)) {
      value.forEach(function (p) { if (Array.isArray(p) && p.length >= 2) pairs.push([String(p[0]), String(p[1])]); });
      return pairs;
    }
    if (value && typeof value === "object") {
      Object.keys(value).forEach(function (k) {
        var v = value[k];
        if (v === undefined || v === null) return;
        (Array.isArray(v) ? v : [v]).forEach(function (one) { pairs.push([k, String(one)]); });
      });
    }
    return pairs;
  }

  function parseJSON(text) {
    if (typeof text !== "string" || text.length === 0) return undefined;
    var first = text.replace(/^\s+/, "").charAt(0);
    if (first !== "{" && first !== "[") return undefined;
    try { return JSON.parse(text); } catch (e) { return undefined; }
  }

  function stringify(value) {
    try { return JSON.stringify(value); } catch (e) { return undefined; }
  }

  function parseQuery(url) {
    var query = {};
    var mark = url.indexOf("?");
    if (mark < 0) return query;
    var end = url.indexOf("#", mark);
    var text = url.substring(mark + 1, end < 0 ? url.length : end);
    text.split("&").forEach(function (pair) {
      if (!pair) return;
      var eq = pair.indexOf("=");
      var key = eq < 0 ? pair : pair.substring(0, eq);
      var value = eq < 0 ? "" : pair.substring(eq + 1);
      try { key = decodeURIComponent(key.replace(/\+/g, " ")); } catch (e) {}
      try { value = decodeURIComponent(value.replace(/\+/g, " ")); } catch (e) {}
      if (Object.prototype.hasOwnProperty.call(query, key)) {
        query[key] = [].concat(query[key], value);
      } else {
        query[key] = value;
      }
    });
    return query;
  }

  function withQuery(url, query) {
    var hash = url.indexOf("#");
    var fragment = hash < 0 ? "" : url.substring(hash);
    var base = hash < 0 ? url : url.substring(0, hash);
    var mark = base.indexOf("?");
    if (mark >= 0) base = base.substring(0, mark);
    var parts = [];
    Object.keys(query || {}).forEach(function (k) {
      var v = query[k];
      if (v === undefined || v === null) return;
      (Array.isArray(v) ? v : [v]).forEach(function (one) {
        parts.push(encodeURIComponent(k) + "=" + encodeURIComponent(String(one)));
      });
    });
    return base + (parts.length ? "?" + parts.join("&") : "") + fragment;
  }

  function urlParts(url) {
    var match = /^([a-zA-Z][a-zA-Z0-9+.-]*):\/\/([^\/?#]*)([^?#]*)/.exec(url) || [];
    var authority = match[2] || "";
    var host = authority.replace(/^.*@/, "");
    var port = "";
    var portMatch = /^(\[[^\]]*\]|[^:]*)(?::(\d+))?$/.exec(host);
    if (portMatch) { host = portMatch[1]; port = portMatch[2] || ""; }
    return { scheme: (match[1] || "").toLowerCase(), host: host, port: port ? Number(port) : null, path: match[3] || "/" };
  }

  // A message body as the script sees it: `body` text (null when it isn't UTF-8 text), `json`
  // parsed from it when it is JSON, and `bodyBase64` for the raw bytes.
  function bodyFields(object, input, textKey, base64Key) {
    object[textKey] = input.text;
    object[base64Key] = input.base64;
    var json = parseJSON(input.text);
    if (json !== undefined) object.json = json;
    return { text: input.text, base64: input.base64, json: stringify(json) };
  }

  // Which of the three body fields the script changed, as {text} or {base64}; null when none.
  function bodyChange(object, before, textKey, base64Key) {
    var text = object[textKey];
    if (text !== before.text && text !== undefined) {
      if (text === null) return { text: "" };
      if (typeof text === "object") return { text: stringify(text) || "" };
      return { text: String(text) };
    }
    if (object.json !== undefined || before.json !== undefined) {
      var json = stringify(object.json);
      if (json !== before.json) return { text: object.json === undefined ? "" : (json || "") };
    }
    var base64 = object[base64Key];
    if (base64 !== before.base64 && typeof base64 === "string") return { base64: base64 };
    return null;
  }

  function makeRequest(input) {
    var headers = makeHeaders(input.headers);
    var parts = urlParts(input.url);
    var request = {
      method: input.method,
      url: input.url,
      scheme: parts.scheme,
      host: parts.host,
      port: parts.port,
      path: parts.path,
      query: parseQuery(input.url),
      headers: headers.proxy
    };
    var before = bodyFields(request, input.body, "body", "bodyBase64");
    return { value: request, headers: headers, body: before, url: input.url, query: stringify(request.query) };
  }

  function readRequest(made, value) {
    var request = value && typeof value === "object" ? value : made.value;
    var url = typeof request.url === "string" ? request.url : made.url;
    var query = stringify(request.query);
    if (url === made.url && query !== made.query) url = withQuery(url, request.query);
    return {
      method: typeof request.method === "string" ? request.method : made.value.method,
      url: url,
      headers: headerPairs(request.headers === undefined ? made.headers.proxy : request.headers, made.headers),
      body: bodyChange(request, made.body, "body", "bodyBase64")
    };
  }

  function makeResponse(input) {
    var headers = makeHeaders(input.headers);
    var response = { status: input.status, headers: headers.proxy };
    var before = bodyFields(response, input.body, "body", "bodyBase64");
    return { value: response, headers: headers, body: before };
  }

  function readResponse(made, value) {
    var response = value && typeof value === "object" ? value : made.value;
    var status = Number(response.status);
    return {
      status: isFinite(status) ? Math.round(status) : made.value.status,
      headers: headerPairs(response.headers === undefined ? made.headers.proxy : response.headers, made.headers),
      body: bodyChange(response, made.body, "body", "bodyBase64")
    };
  }

  var RESPONSE = "__wiretideResponse";

  // respond(status, body, headers) or respond({ status, headers, body | json }): returned from
  // onRequest, it answers the request without contacting the server.
  global.respond = function (status, body, headers) {
    var options = status && typeof status === "object" ? status : { status: status, body: body, headers: headers };
    var result = {};
    result[RESPONSE] = true;
    result.status = options.status === undefined ? 200 : options.status;
    var pairs = headerPairs(options.headers || {}, { proxy: null });
    var content = options.body;
    if (options.json !== undefined) content = options.json;
    var hasType = pairs.some(function (p) { return p[0].toLowerCase() === "content-type"; });
    if (content !== undefined && content !== null && typeof content === "object") {
      content = JSON.stringify(content, null, 2);
      if (!hasType) pairs.push(["Content-Type", "application/json"]);
    } else if (!hasType && content !== undefined && content !== null) {
      pairs.push(["Content-Type", "text/plain; charset=utf-8"]);
    }
    result.headers = pairs;
    result.body = content === undefined || content === null ? "" : String(content);
    return result;
  };

  function call(name, args, build) {
    logs = [];
    var hook = global[name];
    var out = { logs: logs };
    if (typeof hook !== "function") {
      out.skipped = true;
      return JSON.stringify(out);
    }
    try {
      var value = hook.apply(null, args);
      if (value && typeof value.then === "function") {
        throw new Error(name + " returned a Promise; scripts run synchronously, so return the value itself");
      }
      build(out, value);
    } catch (error) {
      out.error = error instanceof Error ? (error.name + ": " + error.message) : ("Uncaught " + show(error));
      if (error && error.line !== undefined) out.line = error.line;
    }
    out.logs = logs;
    return JSON.stringify(out);
  }

  global.__wiretide = {
    hooks: function () {
      return JSON.stringify({
        request: typeof global.onRequest === "function",
        response: typeof global.onResponse === "function",
        publish: typeof global.onPublish === "function"
      });
    },
    request: function (json) {
      var input = JSON.parse(json);
      var made = makeRequest(input.request);
      return call("onRequest", [made.value], function (out, value) {
        if (value && value[RESPONSE]) {
          out.response = { status: Number(value.status) || 200, headers: value.headers, body: { text: value.body } };
          out.request = readRequest(made, made.value);
        } else {
          out.request = readRequest(made, value);
        }
      });
    },
    response: function (json) {
      var input = JSON.parse(json);
      var request = makeRequest(input.request).value;
      Object.freeze(request);
      var made = makeResponse(input.response);
      return call("onResponse", [request, made.value], function (out, value) {
        out.response = readResponse(made, value);
      });
    },
    publish: function (json) {
      var input = JSON.parse(json).message;
      var message = {
        topic: input.topic,
        qos: input.qos,
        retain: input.retain,
        direction: input.direction,
        broker: input.broker,
        clientId: input.clientId
      };
      var before = bodyFields(message, input.payload, "payload", "payloadBase64");
      return call("onPublish", [message], function (out, value) {
        var result = value && typeof value === "object" ? value : message;
        out.message = {
          topic: typeof result.topic === "string" ? result.topic : input.topic,
          retain: typeof result.retain === "boolean" ? result.retain : input.retain,
          payload: bodyChange(result, before, "payload", "payloadBase64")
        };
      });
    }
  };
})(this);
"""#
}
