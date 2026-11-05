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

// Click any screenshot to see it full size. Esc, the close button or a click outside the image
// closes it; the arrow keys step through every screenshot on the page.
(() => {
  const pictures = [...document.querySelectorAll("main figure picture")];
  if (!pictures.length || typeof HTMLDialogElement !== "function") return;

  const icon = (d) => `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="${d}"/></svg>`;
  const dialog = document.createElement("dialog");
  dialog.className = "lightbox";
  dialog.setAttribute("aria-label", "Screenshot");
  dialog.innerHTML = `
    <div class="lightbox-stage"><img alt=""></div>
    <p class="lightbox-caption"><span class="lightbox-count"></span><span class="lightbox-text"></span></p>
    <button type="button" class="lightbox-prev" aria-label="Previous screenshot">${icon("M15.4 6.4 14 5l-7 7 7 7 1.4-1.4L9.8 12z")}</button>
    <button type="button" class="lightbox-next" aria-label="Next screenshot">${icon("M8.6 6.4 10 5l7 7-7 7-1.4-1.4 5.6-5.6z")}</button>
    <button type="button" class="lightbox-close" aria-label="Close">${icon("M18.3 7.1 16.9 5.7 12 10.6 7.1 5.7 5.7 7.1l4.9 4.9-4.9 4.9 1.4 1.4 4.9-4.9 4.9 4.9 1.4-1.4-4.9-4.9z")}</button>`;
  document.body.append(dialog);

  const big = dialog.querySelector(".lightbox-stage img");
  const count = dialog.querySelector(".lightbox-count");
  const text = dialog.querySelector(".lightbox-text");
  let index = 0;
  let opener = null;

  const show = (i) => {
    index = (i + pictures.length) % pictures.length;
    const img = pictures[index].querySelector("img");
    const caption = pictures[index].closest("figure").querySelector("figcaption");
    big.src = img.currentSrc || img.src; // currentSrc follows the light or dark source in use
    big.alt = img.alt;
    count.textContent = `${index + 1} / ${pictures.length}`;
    text.textContent = caption ? caption.textContent : img.alt;
  };

  pictures.forEach((picture, i) => {
    const img = picture.querySelector("img");
    const button = document.createElement("button");
    button.type = "button";
    button.className = "zoom";
    button.setAttribute("aria-label", `Enlarge screenshot: ${img.alt}`);
    button.setAttribute("aria-haspopup", "dialog");
    picture.replaceWith(button);
    button.append(picture);
    button.addEventListener("click", () => {
      opener = button;
      img.loading = "eager";
      show(i);
      dialog.showModal();
      dialog.querySelector(".lightbox-close").focus();
    });
  });

  dialog.querySelector(".lightbox-prev").addEventListener("click", () => show(index - 1));
  dialog.querySelector(".lightbox-next").addEventListener("click", () => show(index + 1));
  dialog.querySelector(".lightbox-close").addEventListener("click", () => dialog.close());
  // A click on the dimmed area (the stage around the image, or the backdrop) closes.
  dialog.addEventListener("click", (event) => {
    if (event.target === dialog || event.target.classList.contains("lightbox-stage")) dialog.close();
  });
  dialog.addEventListener("keydown", (event) => {
    if (event.key === "ArrowLeft") { event.preventDefault(); show(index - 1); }
    if (event.key === "ArrowRight") { event.preventDefault(); show(index + 1); }
  });
  dialog.addEventListener("close", () => {
    big.removeAttribute("src");
    if (opener) opener.focus();
  });
})();
