import std/unittest

import matter/theme

const jsonTheme =
  """
{
  "name": "Example",
  "settings": [
    {"settings": {
      "foreground": "#112233", "background": "#445566",
      "fontFamily": "Example Mono", "fontSize": 12, "lineHeight": 16
    }},
    {"scope": "source.example, entity.name", "settings": {
      "foreground": "#ABC", "fontStyle": "italic"
    }},
    {"scope": ["constant.numeric", "storage.type"], "settings": {
      "foreground": "#1234"
    }}
  ]
}
"""

const plistTheme =
  """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>name</key><string>Example</string>
  <key>settings</key><array>
    <dict><key>settings</key><dict>
      <key>foreground</key><string>#112233</string>
      <key>background</key><string>#445566</string>
      <key>fontFamily</key><string>Example Mono</string>
      <key>fontSize</key><real>12</real>
      <key>lineHeight</key><integer>16</integer>
    </dict></dict>
    <dict><key>scope</key><string>source.example, entity.name</string><key>settings</key><dict>
      <key>foreground</key><string>#ABC</string>
      <key>fontStyle</key><string>italic</string>
    </dict></dict>
    <dict><key>scope</key><array><string>constant.numeric</string><string>storage.type</string></array><key>settings</key><dict>
      <key>foreground</key><string>#1234</string>
    </dict></dict>
  </array>
</dict></plist>
"""

proc color(theme: Theme, id: int): string =
  theme.colorMap()[id]

suite "TextMate themes":
  test "JSON and plist themes resolve the same defaults and colors":
    let json = newTheme(parseRawTheme(jsonTheme, "example.tmTheme.json"))
    let plist = newTheme(parseRawTheme(plistTheme, "example.tmTheme"))
    check json.defaults().fontFamily == "Example Mono"
    check json.defaults().fontSize == 12.0
    check json.defaults().lineHeight == 16.0
    check json.match([]) == json.defaults()
    check json.colorMap() == plist.colorMap()
    let jsonStyle = json.match(["source.example", "entity.name.function"])
    let plistStyle = plist.match(["source.example", "entity.name.function"])
    check jsonStyle == plistStyle
    check jsonStyle.fontStyle == fontStyleItalic
    check json.color(jsonStyle.foregroundId) == "#ABC"

  test "inherits fields and ranks scope paths by specificity":
    let theme = newTheme(
      parseRawTheme(
        """{
        "settings": [
          {"settings": {"foreground": "#111111", "background": "#222222",
            "fontFamily": "Mono", "fontSize": 11, "lineHeight": 14}},
          {"scope": ["bar", "baz"], "settings": {"background": "#333333"}},
          {"scope": "constant", "settings": {"fontStyle": "italic", "foreground": "#444444"}},
          {"scope": "constant.numeric", "settings": {"foreground": "#555555"}},
          {"scope": "constant.numeric.hex", "settings": {"fontStyle": "bold"}},
          {"scope": "constant.numeric.dec", "settings": {"fontStyle": "", "foreground": "#666666"}},
          {"scope": "source.css selector > bar", "settings": {"fontStyle": "bold"}}
        ]
      }""",
        "specificity.json",
      )
    )
    let hex = theme.match(["source.test", "constant.numeric.hex.extra"])
    check hex.fontStyle == fontStyleBold
    check theme.color(hex.foregroundId) == "#555555"
    check hex.fontFamily == "Mono"
    check hex.fontSize == 11.0
    check hex.lineHeight == 14.0
    let decimal = theme.match(["constant.numeric.dec"])
    check decimal.fontStyle == fontStyleNone
    check theme.color(decimal.foregroundId) == "#666666"
    let directChild = theme.match(["source.css", "selector", "bar"])
    check directChild.fontStyle == fontStyleBold
    check theme.color(directChild.backgroundId) == "#333333"
    let indirectChild = theme.match(["source.css", "selector", "meta.selector", "bar"])
    check indirectChild.fontStyle == fontStyleNotSet

  test "parses combined font styles":
    let theme = newTheme(
      parseRawTheme(
        """{"settings": [{"scope": "keyword", "settings": {
        "fontStyle": "italic bold underline strikethrough"
      }}]}""",
        "font.json",
      )
    )
    let style = theme.match(["keyword.control"])
    check style.fontStyle.contains(fontStyleItalic)
    check style.fontStyle.contains(fontStyleBold)
    check style.fontStyle.contains(fontStyleUnderline)
    check style.fontStyle.contains(fontStyleStrikethrough)
    check style.fontStyle.fontStyleValue() == 15

  test "accepts every supported hexadecimal color width":
    let theme = newTheme(
      parseRawTheme(
        """{"settings": [{"settings": {
        "foreground": "#ABC", "background": "#11223344"
      }}, {"scope": "rgba", "settings": {"foreground": "#1234"}}]}""",
        "hex.json",
      )
    )
    check theme.color(theme.defaults().foregroundId) == "#ABC"
    check theme.color(theme.defaults().backgroundId) == "#11223344"
    check theme.color(theme.match(["rgba"]).foregroundId) == "#1234"

  test "skips settings entries without a settings object":
    let raw = parseRawTheme(
      """{"settings": [
        {"name": "ignored"},
        {"settings": {"foreground": "#112233"}}
      ]}""",
      "missing-settings.json",
    )
    check raw.settings.len == 1
    let theme = newTheme(raw)
    check theme.color(theme.defaults().foregroundId) == "#112233"

  test "freezes caller supplied color IDs":
    let raw = parseRawTheme(
      """{"settings": [
        {"settings": {"foreground": "#000000", "background": "#FFFFFF"}},
        {"scope": "keyword", "settings": {"foreground": "#FF0000"}}
      ]}""",
      "frozen.json",
    )
    let theme = newTheme(raw, @["", "#000000", "#FFFFFF", "#FF0000"])
    check theme.defaults().foregroundId == 1
    check theme.defaults().backgroundId == 2
    check theme.match(["keyword"]).foregroundId == 3
    var copy = theme.colorMap()
    copy[3] = "#000000"
    check theme.colorMap()[3] == "#FF0000"
    expect ThemeError:
      discard newTheme(raw, @["", "#000000", "#FFFFFF"])

  test "matches reference child and deeper parent specificity":
    let childTheme = newTheme(
      parseRawTheme(
        """{"settings": [
        {"settings": {"foreground": "#100000"}},
        {"scope": "b a", "settings": {"foreground": "#200000"}},
        {"scope": "b > a", "settings": {"foreground": "#300000"}},
        {"scope": "c > b > a", "settings": {"foreground": "#400000"}},
        {"scope": "a", "settings": {"foreground": "#500000"}}
      ]}""",
        "child.json",
      )
    )
    check childTheme.color(childTheme.match(["b", "a"]).foregroundId) == "#300000"
    check childTheme.color(childTheme.match(["b", "c", "a"]).foregroundId) == "#200000"
    check childTheme.color(childTheme.match(["c", "b", "a"]).foregroundId) == "#400000"
    check childTheme.color(childTheme.match(["c", "b", "d", "a"]).foregroundId) ==
      "#200000"

    let deeperTheme = newTheme(
      parseRawTheme(
        """{"settings": [
        {"settings": {"foreground": "#100000"}},
        {"scope": "y.z a.b", "settings": {"foreground": "#200000"}},
        {"scope": "x y a.b", "settings": {"foreground": "#300000"}}
      ]}""",
        "deeper.json",
      )
    )
    check deeperTheme.match(["x", "a.b"]).foregroundId == 0
    check deeperTheme.color(deeperTheme.match(["x", "y", "a.b"]).foregroundId) ==
      "#300000"
    check deeperTheme.color(deeperTheme.match(["x", "y.z", "a.b"]).foregroundId) ==
      "#200000"

  test "ranks asymmetric child combinators by their aligned parents":
    let theme = newTheme(
      parseRawTheme(
        """{"settings": [
        {"scope": "x > parent a", "settings": {"foreground": "#200000"}},
        {"scope": "x.long parent a", "settings": {"foreground": "#300000"}}
      ]}""",
        "asymmetric-child.json",
      )
    )
    check theme.color(theme.match(["x.long", "parent", "a"]).foregroundId) == "#300000"

  test "matches reference inheritance and overwrite boundaries":
    let theme = newTheme(
      parseRawTheme(
        """{"settings": [
        {"settings": {"foreground": "#100000", "fontFamily": "Mono", "fontSize": 10}},
        {"settings": {"background": "#200000", "fontStyle": "italic"}},
        {"scope": ",, var, constant,,", "settings": {"foreground": "#300000"}},
        {"scope": "var", "settings": {"fontStyle": "bold"}},
        {"scope": "source.css var", "settings": {"foreground": "#400000"}},
        {"scope": "source.css var", "settings": {"fontStyle": "underline"}},
        {"scope": "var.identifier", "settings": {"foreground": "#500000"}}
      ]}""",
        "inheritance.json",
      )
    )
    let defaults = theme.defaults()
    check defaults.fontStyle == fontStyleItalic
    check theme.color(defaults.foregroundId) == "#100000"
    check theme.color(defaults.backgroundId) == "#200000"
    let unmatched = theme.match(["plain"])
    check unmatched.fontStyle == fontStyleNotSet
    check unmatched.foregroundId == 0
    check unmatched.backgroundId == 0
    check unmatched.fontFamily == "Mono"
    check unmatched.fontSize == 10.0
    let inheritedParent = theme.match(["source.css", "nested", "var.other"])
    check inheritedParent.fontStyle == fontStyleUnderline
    check theme.color(inheritedParent.foregroundId) == "#400000"
    let deeperMain = theme.match(["source.css", "var.identifier"])
    check deeperMain.fontStyle == fontStyleBold
    check theme.color(deeperMain.foregroundId) == "#500000"
    check theme.color(theme.match(["constant.numeric"]).foregroundId) == "#300000"

  test "matches #23460 and ignores invalid colors":
    let issueTheme = newTheme(
      parseRawTheme(
        """{"settings": [
        {"settings": {"foreground": "#AEC2E0", "background": "#14191F"}},
        {"scope": "meta.structure.dictionary.json string.quoted.double.json", "settings": {"foreground": "#FF410D"}},
        {"scope": "meta.structure.dictionary.json string.quoted.double.json", "settings": {"foreground": "#FFFFFF"}},
        {"scope": "meta.structure.dictionary.value.json string.quoted.double.json", "settings": {"foreground": "#FF410D"}}
      ]}""",
        "23460.json",
      )
    )
    check issueTheme.color(
      issueTheme.match(
        [
          "source.json", "meta.structure.dictionary.json",
          "meta.structure.dictionary.value.json", "string.quoted.double.json",
        ]
      ).foregroundId
    ) == "#FF410D"
    let invalidTheme = newTheme(
      parseRawTheme(
        """{"settings": [{"scope": "variable.parameter", "settings": {
        "fontStyle": "italic", "foreground": ""
      }}]}""",
        "invalid-color.json",
      )
    )
    let invalidStyle = invalidTheme.match(["variable.parameter"])
    check invalidStyle.fontStyle == fontStyleItalic
    check invalidStyle.foregroundId == 0

  test "rejects malformed roots and plist entities":
    expect ThemeError:
      discard parseRawTheme("[]", "bad.json")
    expect ThemeError:
      discard parseRawTheme(
        "<!ENTITY x SYSTEM \"file:///etc/passwd\"><plist><dict/></plist>", "bad.tmTheme"
      )
