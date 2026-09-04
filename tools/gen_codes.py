#!/usr/bin/env python3
"""Generate the ISO code tables used by src/interop.

Source of record:
  * ISO 3166-1 countries and ISO 4217 currencies: the `pycountry` package,
    which packages the ISO-published code lists.
  * ISO 4217 minor units: CLDR currency fraction data via the `babel` package.
  * ISO 639-1 language codes and ISO 15924 script codes: `pycountry`.

Run:  python3 tools/gen_codes.py
The generated files are checked in so that a build never needs the network.
"""
import datetime
import pycountry
from babel.core import get_global

HEADER = """// GENERATED FILE - do not edit by hand.
// Regenerate with: python3 tools/gen_codes.py
// Source: {source}
// Generated: {when}
"""

WHEN = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def zstr(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def gen_countries(path: str) -> None:
    rows = sorted(pycountry.countries, key=lambda c: c.alpha_2)
    with open(path, "w") as f:
        f.write(HEADER.format(source="ISO 3166-1 via pycountry", when=WHEN))
        f.write("""
const std = @import("std");

/// One ISO 3166-1 country entry. `numeric` is the ISO 3166-1 numeric code.
pub const Country = struct {
    alpha2: [2]u8,
    alpha3: [3]u8,
    numeric: u16,
    name: []const u8,
};

/// Sorted by alpha-2 code so lookups can use binary search.
pub const table = [_]Country{
""")
        for c in rows:
            f.write(
                "    .{{ .alpha2 = \"{a2}\".*, .alpha3 = \"{a3}\".*, .numeric = {num}, .name = {name} }},\n".format(
                    a2=c.alpha_2, a3=c.alpha_3, num=int(c.numeric), name=zstr(c.name)
                )
            )
        f.write("};\n")


def gen_currencies(path: str) -> None:
    fractions = get_global("currency_fractions")
    default_digits = fractions["DEFAULT"][0]
    rows = sorted(pycountry.currencies, key=lambda c: c.alpha_3)
    with open(path, "w") as f:
        f.write(HEADER.format(source="ISO 4217 via pycountry; minor units via CLDR/babel", when=WHEN))
        f.write("""
const std = @import("std");

/// One ISO 4217 currency entry. `minor_units` is the number of decimal digits
/// the currency is normally written with; amounts are stored as integers in
/// those minor units so that money never travels as a float.
pub const Currency = struct {
    code: [3]u8,
    numeric: u16,
    minor_units: u8,
    name: []const u8,
};

/// Sorted by alphabetic code so lookups can use binary search.
pub const table = [_]Currency{
""")
        for c in rows:
            digits = fractions.get(c.alpha_3, (default_digits,))[0]
            numeric = int(c.numeric) if getattr(c, "numeric", None) else 0
            f.write(
                "    .{{ .code = \"{code}\".*, .numeric = {num}, .minor_units = {digits}, .name = {name} }},\n".format(
                    code=c.alpha_3, num=numeric, digits=digits, name=zstr(c.name)
                )
            )
        f.write("};\n")


def gen_languages(path: str) -> None:
    langs = sorted(
        {l.alpha_2: l for l in pycountry.languages if hasattr(l, "alpha_2")}.values(),
        key=lambda l: l.alpha_2,
    )
    scripts = sorted(pycountry.scripts, key=lambda s: s.alpha_4)
    with open(path, "w") as f:
        f.write(HEADER.format(source="ISO 639-1 and ISO 15924 via pycountry", when=WHEN))
        f.write("""
const std = @import("std");

pub const Language = struct {
    code: [2]u8,
    name: []const u8,
};

pub const Script = struct {
    code: [4]u8,
    name: []const u8,
};

/// ISO 639-1 two-letter language codes, sorted.
pub const languages = [_]Language{
""")
        for l in langs:
            f.write("    .{{ .code = \"{c}\".*, .name = {n} }},\n".format(c=l.alpha_2, n=zstr(l.name)))
        f.write("};\n\n/// ISO 15924 script codes, sorted.\npub const scripts = [_]Script{\n")
        for s in scripts:
            f.write("    .{{ .code = \"{c}\".*, .name = {n} }},\n".format(c=s.alpha_4, n=zstr(s.name)))
        f.write("};\n")


if __name__ == "__main__":
    gen_countries("src/interop/iso3166_data.zig")
    gen_currencies("src/interop/iso4217_data.zig")
    gen_languages("src/interop/iso639_data.zig")
    print("generated country, currency and language tables")
