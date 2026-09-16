# Turgai brand and typography plan

## Brand direction

Turgai means skylark in Tatar. The product should feel like an open horizon:
calm, capable, spacious, curious, and grounded in the steppe. The sky and
freedom idea should appear through proportion, rhythm, color, and movement;
the interface should not depend on literal clouds, gradients, or decorative
bird imagery.

The brand promise is: **build useful abilities with clarity and freedom**.

## Typography principles

Typography is a system, not just a font choice. It should coordinate typeface,
scale, weight, leading, tracking, color, alignment, and composition so that it
is readable, information is prioritized, and Turgai has a recognizable voice.

Use these semantic roles:

- Brand display: wordmark, onboarding, and major brand statements.
- Page title: the primary purpose of the current screen.
- Section title: a major group such as Name and access, Inputs, or Action.
- Body: descriptions and entered values.
- Label: the name of a field or control.
- Helper: short instructions that explain a decision.
- Metadata: status, kind, approval, filenames, and other secondary facts.
- Code: URLs, scripts, headers, and variables.

The product UI should use a system font for body text, labels, controls, and
code. A distinctive humanist or editorial display face may be tested for brand
moments and major headings, but it should not be used in dense forms until it
proves legible and technically reliable.

Brand typography should be recognizable through repeated behavior: the title
scale, weight pairings, spacing, sentence case, alignment, color, and use of
the skylark mark. The font alone is not the brand.

## Visual language

- Sky: a pale blue canvas and quiet blue surfaces.
- Steppe: warm ochre/brown for selected actions and brand accents.
- Ink: deep blue-gray for primary text.
- Mist: a readable blue-gray for secondary text; never let helper text fade
  into the canvas.
- Horizon: restrained horizontal rules that group content without boxing every
  section.
- Flight path: workflow steps should read as a clear top-to-bottom sequence.

Use brand color intentionally for actions, links, and meaningful states. Keep
running text neutral and high contrast.

## Implementation phases

### 1. Brand foundation

Create a short visual brief covering personality, tone, type direction, color
roles, capitalization, spacing, and examples of what Turgai is and is not.
Compare three type directions:

1. system-only and proportion-led;
2. system text with a restrained display companion;
3. one warm humanist family across the product.

Choose the direction that remains clear in the tool editor, not only in a hero
screen.

### 2. Typography tokens

Keep one source of truth for the roles above. Define size, leading, weight,
tracking, color, and responsive behavior together. Use `rem` and responsive
values so browser zoom and larger text remain usable. Use metadata sizing only
for genuinely secondary information.

### 3. Tools editor composition

Group the editor by task. Each major section should own its heading,
explanation, and controls through shared alignment, whitespace, and a
restrained horizon rule—not by putting unrelated content into a rounded card.
Give section explanations enough width to form natural lines. Make the
required path obvious and keep optional configuration secondary.

Use the workflow structure as the product metaphor: step number, action,
required input, optional configuration, and result passed forward.

### 4. CSS consolidation

Refactor `turgai.css` into tokens, base typography, shared components, tools,
editor, and responsive rules. Remove duplicate generations of rules and make
one final rule responsible for each control and text role.

### 5. Accessibility and content

Check contrast, placeholders, focus states, browser zoom, reduced motion, and
long labels. Test English and Tatar/Cyrillic content, including the letters
`ә`, `ө`, `ү`, `җ`, `ң`, and `һ`. Keep UI copy short, direct, and in sentence
case.

## Acceptance criteria

- A user can distinguish title, section title, label, helper text, and metadata
  at a glance.
- Empty fields do not look disabled because their examples are unreadable.
- The page feels spacious but not empty or visually washed out.
- Turgai remains recognizable when the logo is not visible.
- The layout survives long names, long descriptions, multiple workflow steps,
  errors, localization, and 200% browser zoom.
- Typography feels open, grounded, and capable without becoming decorative.

## References

- [Apple Human Interface Guidelines: Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
- [Apple Human Interface Guidelines: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [GOV.UK Brand Guidelines: Typography](https://brand.design-system.service.gov.uk/typography/)
- [Maersk Design System: Typography](https://designsystem.maersk.com/foundations/typography/)
- [IBM Carbon Design System: Typography](https://v10.carbondesignsystem.com/guidelines/typography/overview/)
- [U.S. Web Design System: Typography](https://designsystem.digital.gov/components/typography/)
- [W3C WCAG: Contrast](https://www.w3.org/WAI/WCAG21/Understanding/contrast-minimum)
