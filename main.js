(() => {
  const site = window.SITE || {};

  if (site.downloadURL) {
    document.querySelectorAll("[data-download]").forEach((a) => { a.href = site.downloadURL; });
  }

  if (site.checkoutURL) {
    document.querySelectorAll("[data-checkout]").forEach((a) => {
      a.href = site.checkoutURL;
      a.textContent = "Buy Pro";
    });
  }

  const form = document.querySelector("[data-waitlist]");
  const fallback = document.querySelector("[data-waitlist-fallback]");
  if (!form || !site.waitlistEndpoint) return;

  form.hidden = false;
  if (fallback) fallback.hidden = true;
  const status = form.querySelector(".form-status");
  const button = form.querySelector("button");

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    button.disabled = true;
    status.textContent = "Joining…";
    try {
      const response = await fetch(site.waitlistEndpoint, {
        method: "POST",
        headers: { Accept: "application/json" },
        body: new FormData(form),
      });
      if (!response.ok) throw new Error(String(response.status));
      form.reset();
      status.textContent = "You're on the list. We'll email you when Pro opens.";
    } catch {
      status.textContent = "That didn't go through. Please try again in a moment.";
    } finally {
      button.disabled = false;
    }
  });
})();
