import Elementary
import Foundation

/// The whole document a browser opens: the page, kept live by the website's `/live` stream. Each
/// page shown after it is morphed into the one there, and animated as SwiftUI animates a change:
/// a thing with an `id` is the same thing on both pages, and slides from where it was to where it
/// is, by the edges its box lines it up by, its old look fading out where it was if it changed;
/// anything else that's new or changed fades in, and what's gone fades out.
struct PageDocument: HTMLDocument {
    let layout: Layout
    let version: Int

    var title: String { "Website" }
    var lang: String { "en" }

    var head: some HTML {
        meta(.name(.viewport), .content("width=device-width, initial-scale=1"))
        style { HTMLRaw(Self.css) }
        script(.src("https://unpkg.com/idiomorph@0.7.4/dist/idiomorph.js")) {}
    }

    var body: some HTML {
        main {
            LayoutView(layout: layout, version: version)
        }
        script { HTMLRaw(Self.live) }
    }

    /// Shows each page `/live` sends, morphed into the one shown, so only what changed changes,
    /// then animated, unless motion is reduced: each thing is measured before the morph and after
    /// it, and goes from the one to the other. A thing with an `id` (`data-anchor`) slides, moved
    /// by the point its box lines it up by, less what the slides around it already move it; any
    /// other thing that moved in its box, or whose own look changed, fades in, unless what it's in
    /// already does; a copy of what's gone, or of a look replaced, fades out where it was. A box's
    /// own look is its kind, not what's in it. A press posts the button's press, read when it's pressed, so it
    /// names the page shown then.
    static let live = """
        const page = document.querySelector('main');
        const still = matchMedia('(prefers-reduced-motion: reduce)');
        const timing = { duration: 220, easing: 'ease-out' };

        const look = (el) =>
          el.tagName === 'IMG' ? el.getAttribute('src') : el.tagName === 'DIV' ? el.className : el.className + '|' + el.textContent;
        const point = (rect, anchor) => {
          const [across, down] = (anchor || 'leading top').split(' ');
          return {
            x: across === 'leading' ? rect.left : across === 'trailing' ? rect.right : rect.left + rect.width / 2,
            y: down === 'top' ? rect.top : down === 'bottom' ? rect.bottom : rect.top + rect.height / 2,
          };
        };
        const fadeIn = (el) => el.animate([{ opacity: 0 }, { opacity: 1 }], timing);
        const fadeOut = (el, rect) => {
          const copy = el.cloneNode(true);
          copy.removeAttribute('id');
          copy.querySelectorAll('[id]').forEach((inner) => inner.removeAttribute('id'));
          Object.assign(copy.style, {
            position: 'absolute', left: rect.left + scrollX + 'px', top: rect.top + scrollY + 'px',
            width: rect.width + 'px', height: rect.height + 'px', margin: '0', boxSizing: 'border-box', pointerEvents: 'none',
          });
          document.body.appendChild(copy);
          copy.animate([{ opacity: 1 }, { opacity: 0 }], timing).finished.then(() => copy.remove());
        };

        function show(html) {
          if (still.matches) { Idiomorph.morph(page, html, { morphStyle: 'innerHTML' }); return; }
          const before = new Map();
          for (const el of page.querySelectorAll('[id]')) {
            before.set(el.id, { rect: el.getBoundingClientRect(), look: look(el), copy: el.cloneNode(true) });
          }
          const added = new Set();
          Idiomorph.morph(page, html, { morphStyle: 'innerHTML', callbacks: {
            afterNodeAdded: (node) => { if (node.nodeType === 1) added.add(node); },
            beforeNodeRemoved: (node) => {
              if (node.nodeType === 1 && before.has(node.id)) fadeOut(node, before.get(node.id).rect);
              return true;
            },
          } });
          // For each thing: how far it moved on the page, how far the slides around it carry it,
          // and whether it, or what it's in, fades in.
          const shifts = new Map(), carries = new Map(), fading = new Set();
          for (const el of page.querySelectorAll('[id]')) {
            let box = el.parentElement;
            while (box && box !== page && !shifts.has(box)) box = box.parentElement;
            const boxShift = shifts.get(box) || { x: 0, y: 0 }, carried = carries.get(box) || { x: 0, y: 0 };
            const inFade = fading.has(box);
            const was = before.get(el.id);
            if (added.has(el) || !was) {
              shifts.set(el, boxShift); carries.set(el, carried);
              if (!inFade) { fadeIn(el); fading.add(el); } else { fading.add(el); }
              continue;
            }
            const anchor = el.dataset.anchor;
            const from = point(was.rect, anchor), to = point(el.getBoundingClientRect(), anchor);
            const shift = { x: from.x - to.x, y: from.y - to.y };
            shifts.set(el, shift);
            const changed = look(el) !== was.look;
            if (anchor) {
              const slide = { x: shift.x - carried.x, y: shift.y - carried.y };
              if (Math.abs(slide.x) > 0.5 || Math.abs(slide.y) > 0.5) {
                el.animate([{ transform: `translate(${slide.x}px, ${slide.y}px)` }, { transform: 'none' }], timing);
              }
              carries.set(el, shift);
              if (changed) { fadeOut(was.copy, was.rect); if (!inFade) fadeIn(el); fading.add(el); }
              else if (inFade) fading.add(el);
            } else {
              carries.set(el, carried);
              const movedInBox = Math.abs(shift.x - boxShift.x) > 0.5 || Math.abs(shift.y - boxShift.y) > 0.5;
              if (inFade) fading.add(el);
              else if (changed || movedInBox) { fadeIn(el); fading.add(el); }
            }
          }
        }

        new EventSource('/live').addEventListener('page', (event) => show(event.data));
        page.addEventListener('click', (event) => {
          const button = event.target.closest('button[data-press]');
          if (button) { fetch(button.dataset.press, { method: 'POST' }); }
        });
        """

    static let css = """
        :root { color-scheme: light dark; --gap: 12px; --line: #c8c8cc; --button: #f2f2f5;
                --secondary: #6e6e73; --accent: #0a66d8; --positive: #1f8a3c; --warning: #b25e00; --negative: #c4271d; }
        @media (prefers-color-scheme: dark) { :root { --line: #48484c; --button: #2c2c30;
                --secondary: #a1a1a6; --accent: #4b9dff; --positive: #4cc56d; --warning: #ffa83d; --negative: #ff6b5e; } }
        body { margin: 0; padding: 24px 16px; font: 16px/1.4 system-ui, sans-serif; }
        p { margin: 0; }
        .column { display: flex; flex-direction: column; gap: var(--gap); align-items: center; }
        .row { display: flex; flex-direction: row; flex-wrap: wrap; gap: var(--gap); align-items: center; }
        .row.top { align-items: flex-start; } .row.bottom { align-items: flex-end; }
        .column.leading { align-items: flex-start; } .column.trailing { align-items: flex-end; }
        button { font: inherit; padding: 6px 14px; border: 1px solid var(--line); border-radius: 8px;
                 background: var(--button); color: inherit; cursor: pointer; }
        .title { font-size: 1.75em; font-weight: 700; line-height: 1.2; }
        .heading { font-size: 1.25em; font-weight: 600; }
        .caption { font-size: 0.85em; }
        .emphasis { font-weight: 600; font-style: italic; }
        .secondary { color: var(--secondary); }
        .accent { color: var(--accent); }
        .positive { color: var(--positive); }
        .warning { color: var(--warning); }
        .negative { color: var(--negative); }
        img.image { display: block; max-width: 100%; height: auto; border-radius: 8px; }
        img.fit { object-fit: contain; } img.fill { object-fit: cover; }
        button.prominent { background: var(--accent); border-color: var(--accent); color: white; font-weight: 600; }
        button.destructive { color: var(--negative); border-color: var(--negative); }
        """
}

/// One layout, as HTML: a row or a column as a box of its items, a button posting its label
/// with the page version it was shown on, so a press on a page since replaced is refused. Each
/// thing's HTML `id` is what it is on the page, which the morph keeps it by; only an `id` given
/// makes it slide.
struct LayoutView: HTML {
    let layout: Layout
    let version: Int
    /// Where it is on the page: its index in each box it's in, outermost first.
    var place: [Int] = []
    /// How the box it's in lines it up: the page is a column, centred.
    var anchor = Anchor(horizontal: .center, vertical: .top)

    var body: some HTML {
        switch layout {
        case .row(let id, let items, let alignment, let spacing):
            div(.id(Identity.of(id: id, place: place).name), .class("row \(alignment.rawValue)"), .style("gap: \(Self.points(spacing))")) {
                children(items, Anchor(horizontal: .leading, vertical: alignment))
            }.attributes(contentsOf: named(id))
        case .column(let id, let items, let alignment, let spacing):
            div(.id(Identity.of(id: id, place: place).name), .class("column \(alignment.rawValue)"), .style("gap: \(Self.points(spacing))")) {
                children(items, Anchor(horizontal: alignment, vertical: .top))
            }.attributes(contentsOf: named(id))
        case .text(let id, let text, let style, let color):
            p(.id(Identity.of(id: id, place: place).name), .class("\(style.rawValue) \(color.rawValue)")) { text }.attributes(contentsOf: named(id))
        case .image(let id, let url, let description, let aspectRatio, let fit, let width):
            img(
                .id(Identity.of(id: id, place: place).name), .src(url.absoluteString), .alt(description), .custom(name: "loading", value: "lazy"),
                .class("image \(fit.rawValue)"), .style(Self.imageStyle(aspectRatio, width))
            ).attributes(contentsOf: named(id))
        case .button(let id, let label, let kind):
            button(
                .id((id.map(Identity.id) ?? .label(label)).name), .class(kind.rawValue),
                .data("press", value: Self.press(label, version: version))
            ) { label }.attributes(contentsOf: named(id))
        }
    }

    private func children(_ items: [Layout], _ anchor: Anchor) -> some HTML {
        ForEach(Array(items.enumerated())) { index, item in
            LayoutView(layout: item, version: version, place: place + [index], anchor: anchor)
        }
    }

    /// When it has an `id`, the edges its box lines it up by: it's the same thing on the page
    /// before and after, and slides by them. Without one, it fades.
    private func named<Tag: HTMLTrait.Attributes.Global>(_ id: String?) -> [HTMLAttribute<Tag>] {
        id.map { _ in [.data("anchor", value: anchor.classes)] } ?? []
    }

    /// How a box lines up what's in it, across and down: a column lines its items up by its
    /// alignment and stacks them from the top; a row lines them up from the leading edge, and
    /// down by its alignment.
    struct Anchor: Equatable {
        let horizontal: ColumnAlignment
        let vertical: RowAlignment

        var classes: String { "\(horizontal.rawValue) \(vertical.rawValue)" }
    }

    /// What a thing on the page is, from one page to the next, as the morph keeps it: its id, a
    /// button's label, or its place.
    enum Identity {
        case id(String)
        case label(String)
        case place([Int])

        static func of(id: String?, place: [Int]) -> Identity { id.map(Identity.id) ?? .place(place) }

        /// As CSS names it: each kind apart, every character outside a name's own written in hex.
        var name: String {
            switch self {
            case .id(let id): "id-" + Self.escaped(id)
            case .label(let label): "label-" + Self.escaped(label)
            case .place(let place): "item" + place.map { "-\($0)" }.joined()
            }
        }

        private static func escaped(_ text: String) -> String {
            text.unicodeScalars.map { scalar in
                CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII ? String(scalar) : "_\(String(scalar.value, radix: 16))_"
            }.joined()
        }
    }

    /// A picture's shape and width, as CSS has them.
    static func imageStyle(_ aspectRatio: AspectRatio, _ width: Double?) -> String {
        let ratio: String? =
            switch aspectRatio {
            case .original: nil
            case .square: "1 / 1"
            case .landscape: "4 / 3"
            case .wide: "16 / 9"
            case .portrait: "3 / 4"
            }
        return (ratio.map { "aspect-ratio: \($0); " } ?? "") + (width.map { "width: \(points($0)); " } ?? "")
    }

    /// Points as the web writes them: a SwiftUI point is a CSS pixel.
    static func points(_ value: Double) -> String {
        value.rounded() == value ? "\(Int(value))px" : "\(value)px"
    }

    static func press(_ label: String, version: Int) -> String {
        let encoded = label.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return "/press?label=\(encoded)&page=\(version)"
    }
}
