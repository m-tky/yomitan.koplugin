local _ = require("gettext")
return {
    fullname = _("Yomitan"),
    version = "0.1.0",
    author = "m-tky",
    url = "https://github.com/m-tky/yomitan.koplugin",
    license = "GPL-3.0-or-later",
    description = _("Experimental Japanese word selection and base-form candidates using preconverted Yomitan indexes. Definitions come only from enabled StarDict dictionaries. Requires custom dictionary provider hooks; not compatible with stock KOReader."),
}
