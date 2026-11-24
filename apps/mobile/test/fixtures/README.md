# Japanese golden test font

`SoramaruTestJP.ttf` is a renamed glyph subset of Noto Sans JP for Flutter tests only. It uses the original variable weights and Japanese glyphs for the synthetic preview copy, plus printable ASCII. See [OFL 1.1](OFL.txt) and the [upstream file at the pinned revision](https://github.com/google/fonts/tree/66a36c8c94b1a5d992ee4e7f392fccfe4945767c/ofl/notosansjp). The test fixture is kept outside application assets. Runtime uses the Japanese system font.

`SoramaruNavigationJP.ttf` is a second renamed Noto Sans JP subset from the same pinned upstream revision. It covers the DEV-02 sample UI and widget-test strings plus printable ASCII for local widget previews and layout tests. The same OFL applies. The original DEV-01 fixture remains fixed for the operating-system-specific golden baselines.
