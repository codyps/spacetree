# App icon

The icon is drawn with AppKit/Core Graphics by `scripts/generate-icon.swift`.
No external dependencies or image generation service are needed.

From the repository root, regenerate the checked-in transparent 1024×1024 PNG:

```sh
swift scripts/generate-icon.swift
```

An optional first argument selects a different output path for previews.
The default output is `Sources/SpaceTree/Resources/AppIcon.png`, loaded through
`Bundle.module` at startup, including when using `swift run SpaceTree`.

The colored rectangles form a treemap with consistent 12-point gutters.
All perimeter rectangles share one rounded clipping path inset 20 points from
the outer outline. Its radius is reduced by the same 20 points, so inner and
outer corner arcs have identical centers and a consistent border thickness.
Interior junctions are square. Edit the tile coordinates and colors in the script
to change the layout; colors follow the app's file category palette.
