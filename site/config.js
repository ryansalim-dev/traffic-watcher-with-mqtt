// Site settings. Edit these, push to main, and the Pages workflow republishes the site.
window.SITE = {
  // Where "Download" goes, e.g. "https://github.com/ryansalim-dev/traffic-watcher-with-mqtt/releases/latest".
  // Empty until v1.0 is published: download buttons read "Get notified" and lead to the waitlist,
  // and the page shows its pre-launch wording. Setting it switches the page to its launch wording.
  downloadURL: "",

  // Lemon Squeezy checkout link for Pro (e.g. https://<store>.lemonsqueezy.com/buy/<variant-id>).
  // Empty: the Pro button points to the waitlist instead.
  checkoutURL: "",

  // Waitlist form endpoint that accepts a POST with an "email" field (Buttondown, Formspree, Loops, ...).
  // Empty: the form is replaced by a note on watching releases on GitHub.
  waitlistEndpoint: "",
};
