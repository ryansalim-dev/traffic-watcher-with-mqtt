(() => {
  const site = window.SITE || {};

  // Launched once there is a download. Until then, download buttons lead to the waitlist.
  if (site.downloadURL) {
    document.querySelectorAll("[data-download]").forEach((a) => {
      a.href = site.downloadURL;
      const label = a.querySelector("[data-label]") || a;
      if (a.dataset.launchLabel) label.textContent = a.dataset.launchLabel;
    });
    document.querySelectorAll("[data-prelaunch]").forEach((el) => { el.hidden = true; });
    document.querySelectorAll("[data-launched]").forEach((el) => { el.hidden = false; });
  }

  if (site.checkoutURL) {
    document.querySelectorAll("[data-checkout]").forEach((a) => {
      a.href = site.checkoutURL;
      a.textContent = "Buy Pro";
    });
  }

  const form = document.querySelector("[data-waitlist]");
  if (!form || !site.waitlistEndpoint) return;

  form.hidden = false;
  document.querySelectorAll("[data-waitlist-fallback]").forEach((el) => { el.hidden = true; });
  document.querySelectorAll("[data-waitlist-copy]").forEach((el) => { el.hidden = false; });
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
