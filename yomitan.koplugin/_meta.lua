local _ = require("gettext")
return {
    fullname = _("Yomitan"),
    version = "0.1.2",
    author = "m-tky",
    url = "https://github.com/m-tky/yomitan.koplugin",
    license = "GPL-3.0-or-later",
    description = _("Experimental Japanese word selection and base-form candidates using preconverted Yomitan indexes. Definitions come only from enabled StarDict dictionaries. Uses KOReader's built-in language-support API; no core patches required. Disable the bundled Japanese plugin before enabling Yomitan."),
}
