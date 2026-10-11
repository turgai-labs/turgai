# Turgai brand and typography plan

This document translates the [brand strategy](./turgai-brand-strategy.md) into visual choices. The shared belief is: **being independent should never mean settling for less.** The emotional direction is **space, exploration, and hope**.

## Starting with the character

Turgai is a small bird with an unruly crest and a presence beyond his size. He is curious, resourceful, warm, and confident enough to take on serious work. His appearance should carry those qualities before anyone reads an explanation.

Open space gives him room. Vibrant color makes him visible. Bold lettering gives him a voice. Simple geometry gives that voice a clear structure. These choices connect the freedom of the sky with the independent attitude described in the strategy.

The steppe and open horizon remain part of the setting. They suggest breadth, light, and space; they do not require every surface to be pale or every accent to be earthy.

## Space, exploration, and hope

Make the vastness of space tangible through scale, distance, light, and open compositions. Explore a bright horizon, a small warm point against deep blue, or a trajectory crossing a broad field. The feeling should be inviting and full of possibility, with the bird providing warmth and a sense of life.

Let compositions range from quiet expanses to bold bursts of color and type. That change in intensity can carry the lift and anticipation of exploration. Preserve the poster energy; spaciousness does not require the whole identity to become subdued.

Use stars, signals, and paths selectively. A brand illustration may suggest a distant world; a working screen should show real content and relationships. Avoid decorative cockpit controls, fabricated telemetry, and constant cosmic effects. The space imagery should give people a horizon without making ordinary tasks feel like operating a spacecraft.

## Composition: a small bird can fill the page

Use the language of graphic posters: strong differences in scale, vivid color fields, clear silhouettes, and purposeful placement. A small skylark beside a large word or a broad field of color can express the character’s ambition.

Build around one clear focal point. A headline, mark, or geometric form should lead the composition, with supporting elements arranged to make the message easy to follow. Let empty space increase the force of that focal point.

Asymmetry and an occasional break in alignment express Turgai’s unruly side. Keep them deliberate and repeatable. A shifted color block or a cropped circle should have a relationship to the type, mark, or page edge.

Brand posters and opening screens can use the widest scale contrasts. Working screens should carry the same confidence through clear headings, strong actions, and precise spacing.

## Color

Use a quiet light or dark base with vibrant accents. Electric blue, signal yellow, hot coral, and vivid violet are directions to explore; they are not yet a fixed palette.

Test expansive sky blue and deep night blue alongside warm yellow or coral points of light. Light mode can carry daylight and an open horizon; dark mode can carry distance and the warmth of something present within it. Space is part of both themes, rather than a reason to make every screen black.

- **Canvas:** a neutral or lightly sky-tinted background that gives content room.
- **Ink:** deep blue-gray or near-black text in light mode, with a readable light equivalent in dark mode.
- **Signal:** a saturated color for focal points, primary actions, and selected geometric forms.
- **Supporting color:** an optional second accent that gives a composition contrast.
- **Secondary text and rules:** readable neutrals that organize information without competing with the focal point.
- **Status:** consistent colors for errors, warnings, and success, supported by words or symbols.

Choose one dominant accent for a composition and use a second only when it contributes. Maintain consistent action and status meanings across the application. A poster can explore a different color pairing without changing what an error or a primary action means in the product.

Warm steppe colors may appear as supporting tones where they suit the composition. They no longer define the primary action palette.

Keep the energy in both light and dark themes. Select text and background pairs for contrast; do not assume a vibrant color is readable as small text.

## Geometry and the mark

Use a small vocabulary of rectangles, bars, circles, and occasional angled cuts. Repeating a few forms gives the identity a recognizable rhythm.

Geometry should frame a message, direct attention, or explain structure. A bar can anchor a heading; a rectangle can give an action presence; a numbered shape can show a workflow sequence. Decorative forms belong where there is room for them.

The skylark is the character’s signature. Preserve a clear silhouette and test the mark at small sizes. Larger compositions may play with scale and cropping, provided the bird remains recognizable. The crest supplies a natural hint of irreverence.

Keep textures and additional motifs sparse. Color, type, and geometry should be enough to express the attitude.

Points, lines, and arcs can suggest contact or travel in brand compositions. In product diagrams, use them to show actual objects, messages, and relationships. Keep decorative signals distinct from activity and status indicators.

## Typography

Typography gives Turgai confidence through scale, weight, spacing, and placement. Explore an assertive sans serif for brand statements, including heavy or condensed directions. Choose it by testing real words and layouts.

Use a readable system font for body text, labels, and controls, with a monospace face for code. A display face should earn its place through recognizable character and reliable language support.

Define these roles:

- **Brand display:** short statements and major brand moments, with the strongest scale and weight.
- **Page title:** a clear statement of the screen’s purpose.
- **Section title:** a major group of related content.
- **Body:** descriptions and entered values.
- **Label:** the name of a field or control.
- **Helper:** instructions that explain a choice.
- **Metadata:** secondary facts such as status or filename.
- **Code:** scripts, URLs, headers, and variables.

Use sentence case in the interface. Short poster statements may use capitals when the composition benefits. Essential text must remain complete and readable; reserve cropping for decorative type or shapes.

Test English and Tatar/Cyrillic content, including `ә`, `ө`, `ү`, `җ`, `ң`, and `һ`. Check fallback fonts as part of the composition.

## Applying the identity

Onboarding and empty states have room for a bold statement, a color field, or a prominent mark. Pair the expression with a clear next step.

Dashboard and list pages should establish hierarchy through confident titles, consistent alignment, and recognizable primary actions. Avoid giving every item equal visual emphasis.

In the tool editor, group each section’s heading, explanation, and controls through spacing and alignment. Let workflow numbers and primary actions carry the color and geometry. Keep field values, instructions, and errors easy to read.

The same voice should run through the copy: direct, helpful, and occasionally irreverent. The visual character should be apparent even when the text is a straightforward instruction.

## Implementation plan

### 1. Test compositions

Compare a few combinations of accent colors, display typography, and geometry using the same content. Include a brand poster, an onboarding screen, and a populated tool editor so the direction is tested at different densities.

Include an open daylight horizon and a deeper space composition, each with the same warm bird and confident typography. Test whether space, exploration, and hope are felt without needing explanatory copy. Include an ordinary task, such as a shopping list, to check that the atmosphere remains welcoming at everyday scale.

Choose the combination that gives the small bird a strong presence and still makes everyday work comfortable. Record the chosen palette, type roles, shapes, and examples in this document.

### 2. Define tokens

Define sizes, leading, weights, tracking, colors, spacing, and geometric dimensions in one place. Use `rem` and responsive values so the hierarchy survives browser zoom and smaller screens.

Keep decorative color roles separate from action and status roles. Document light and dark pairs together.

### 3. Apply shared components

Carry the chosen rules into headers, actions, section introductions, workflow markers, and forms. Consolidate `turgai.css` so each component has a clear set of rules.

### 4. Verify in use

Check populated screens, long labels, errors, multiple workflow steps, keyboard focus, reduced motion, and 200% browser zoom. Validate text and control contrast in both themes. Confirm that decorative elements never obscure content or intercept interaction.

## Acceptance criteria

- The small bird feels resourceful and confident.
- Brand compositions evoke space, exploration, and hope while remaining warm and approachable.
- Everyday tasks feel at home within the identity; metaphor never obscures a control or its meaning.
- Color, geometry, and lettering communicate the independent attitude without an explanatory “punk” label.
- Turgai is recognizable when the logo is absent.
- Each composition has a clear focal point.
- Titles, labels, instructions, and metadata are easy to distinguish.
- Strong brand moments and dense working screens feel like the same product.
- Long content, localization, dark mode, and browser zoom preserve readability and function.

## References

- [Apple Human Interface Guidelines: Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
- [Apple Human Interface Guidelines: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [GOV.UK Brand Guidelines: Typography](https://brand.design-system.service.gov.uk/typography/)
- [Maersk Design System: Typography](https://designsystem.maersk.com/foundations/typography/)
- [IBM Carbon Design System: Typography](https://v10.carbondesignsystem.com/guidelines/typography/overview/)
- [U.S. Web Design System: Typography](https://designsystem.digital.gov/components/typography/)
- [W3C WCAG: Contrast](https://www.w3.org/WAI/WCAG21/Understanding/contrast-minimum)
