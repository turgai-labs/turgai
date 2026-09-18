import AnyLanguageModel
import Elementary
import Hail
import Hummingbird
import HummingbirdElementary
import NIOCore
import TurgaiApplication
import TurgaiHail
import TurgaiPersistence
import TurgaiTelegram

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

struct TurgaiHead: HTML, Sendable {
    var body: some HTML {
        meta(.charset(.utf8))
        meta(.name(.viewport), .content("width=device-width, initial-scale=1, viewport-fit=cover"))
        link(.href("/turgai.css"), .rel(.stylesheet))
        HTMLRaw(
            """
            <script>
            (() => {
                const root = document.documentElement;
                const themeStorageKey = "turgai-theme";
                const systemTheme = window.matchMedia("(prefers-color-scheme: dark)");

                const readSavedTheme = () => {
                    try {
                        const savedTheme = window.localStorage.getItem(themeStorageKey);
                        return savedTheme === "dark" || savedTheme === "light" ? savedTheme : null;
                    } catch (_) {
                        return null;
                    }
                };

                const syncThemeToggle = () => {
                    const toggle = document.querySelector("input[data-theme-toggle]");
                    if (!toggle) return;
                    const dark = root.dataset.theme === "dark";
                    toggle.checked = dark;
                    toggle.setAttribute(
                        "aria-label",
                        dark ? "Switch to light theme" : "Switch to dark theme"
                    );
                    toggle.setAttribute("aria-checked", String(dark));
                };

                const applyTheme = (theme) => {
                    root.dataset.theme = theme;
                    syncThemeToggle();
                };

                const applySystemTheme = () => {
                    try {
                        window.localStorage.removeItem(themeStorageKey);
                    } catch (_) {
                        // Continue with the system theme when storage is unavailable.
                    }
                    applyTheme(systemTheme.matches ? "dark" : "light");
                };

                applyTheme(readSavedTheme() || (systemTheme.matches ? "dark" : "light"));

                const randomAngle = (minimum, maximum) => {
                    return `${(minimum + Math.random() * (maximum - minimum)).toFixed(1)}deg`;
                };

                const randomizeGeometry = () => {
                    const page = document.querySelector(".app-page, .setup-page");
                    if (page) {
                        page.style.setProperty("--geometry-angle-primary", randomAngle(-12, 12));
                        page.style.setProperty("--geometry-angle-secondary", randomAngle(-12, 12));
                        page.style.setProperty("--geometry-angle-tertiary", randomAngle(-18, 18));
                    }
                    document.querySelectorAll(".setup-hero-art .geometry").forEach((shape) => {
                        shape.style.setProperty("--geometry-angle", randomAngle(-18, 18));
                    });
                };

                if (document.readyState === "loading") {
                    document.addEventListener("DOMContentLoaded", randomizeGeometry, { once: true });
                } else {
                    randomizeGeometry();
                }

                if (systemTheme.addEventListener) {
                    systemTheme.addEventListener("change", applySystemTheme);
                } else {
                    systemTheme.addListener(applySystemTheme);
                }

                const bindThemeToggle = () => {
                    const toggle = document.querySelector("input[data-theme-toggle]");
                    if (!toggle || toggle.dataset.themeBound === "true") return;
                    toggle.dataset.themeBound = "true";
                    syncThemeToggle();
                    toggle.addEventListener("change", () => {
                        const theme = toggle.checked ? "dark" : "light";
                        applyTheme(theme);
                        try {
                            window.localStorage.setItem(themeStorageKey, theme);
                        } catch (_) {
                            // Keep the current theme for this page when storage is unavailable.
                        }
                    });
                };
                if (document.readyState === "loading") {
                    document.addEventListener("DOMContentLoaded", bindThemeToggle);
                } else {
                    bindThemeToggle();
                }

                window.addEventListener("storage", (event) => {
                    if (event.key !== themeStorageKey) return;
                    if (event.newValue === "dark" || event.newValue === "light") {
                        applyTheme(event.newValue);
                    } else {
                        applyTheme(systemTheme.matches ? "dark" : "light");
                    }
                });

                const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
                let leaving = false;

                const shouldSkip = (event) => {
                    if (event.defaultPrevented || event.button !== 0) return true;
                    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return true;
                    return false;
                };

                const leave = (continueNavigation) => {
                    if (reducedMotion.matches || leaving) return false;
                    leaving = true;
                    root.classList.add("turgai-page-leaving");
                    window.setTimeout(continueNavigation, 160);
                    return true;
                };

                document.addEventListener("click", (event) => {
                    if (shouldSkip(event)) return;
                    if (!document.querySelector(".setup-page")) return;
                    if (reducedMotion.matches || leaving) return;
                    const link = event.target.closest("a[href]");
                    if (!link || link.hasAttribute("download")) return;
                    if (link.target && link.target !== "_self") return;

                    const destination = new URL(link.href, window.location.href);
                    if (destination.origin !== window.location.origin) return;
                    if (destination.protocol !== window.location.protocol) return;
                    if (
                        destination.pathname === window.location.pathname &&
                        destination.search === window.location.search &&
                        destination.hash
                    ) return;
                    if (destination.href === window.location.href) return;

                    event.preventDefault();
                    leave(() => { window.location.assign(destination.href); });
                });

                document.addEventListener("submit", (event) => {
                    if (event.defaultPrevented) return;
                    if (!document.querySelector(".setup-page")) return;
                    const form = event.target;
                    if (!(form instanceof HTMLFormElement)) return;
                    if (form.target && form.target !== "_self") return;
                    if (reducedMotion.matches || leaving) return;

                    event.preventDefault();
                    leave(() => { HTMLFormElement.prototype.submit.call(form); });
                });

                window.addEventListener("pageshow", () => {
                    leaving = false;
                    root.classList.remove("turgai-page-leaving");
                });
            })();
            </script>
            """
        )
    }
}
