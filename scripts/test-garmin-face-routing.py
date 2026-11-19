#!/usr/bin/env python3
"""Compile and exercise the production Garmin settings model without iOS signing.

JSON is a Codable marker shim here; app serialization extensions and the Garmin
SDK are outside this test. This does not test Bluetooth delivery or SwiftUI UI.
"""
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
TARGETS = {'aviator': '3E7C21A984D54B609C137A2E5F6D0B48', 'navitimer': '7C1A9F426D3B4E589A215F0C8B4D2E77', 'quadrant': 'A92C0A6191C045C18F040F7AB5F92350', 'chronometer': 'C7251B903A4E4F689D126B8E0A5C7F33', 'iwc-perpetual': '3C18D242AC944C1D9421105036042026', 'grandmaster': 'EB6C51900512413B871A6300AA1E2026', 'yacht-master': 'D51783697E4A40D2B636275DF97FA054', 'daytona': '347CD3AC62074088AE01DC3245B49F08', 'sky-dweller': '8D75E2C9B4194C0F976CCB593DCD67C4', 'yacht-master-ii': '62F190D95E084708B1C843991496375B', 'field-gmt': 'A47DBE3091C64875B052AE83DFA74619', 'luminor': 'B17AF08D6F6E47709F1535AB73DDA128', 'premier': '867129CF432B426BAB312B66882D474E', 'lange': 'EC2FB1B77F874F05ABAF1816B196AB91', 'ap-sport': '9BE57722AB1A49D5BB48408CCBB36E51', 'big-bang-reloaded': 'D0798261858B4D1895D38A6937C4FB99'}
source = (ROOT / "Trio/Sources/Models/GarminWatchSettings.swift").read_text()
checks = r'''
let ids = GarminWatchface.garminGlanceFaces.compactMap { $0.watchfaceUUID }
precondition(Set(ids).count == ids.count, "Duplicate push IDs")
let names = Set(GarminWatchface.garminGlanceFaces.map { $0.rawValue })
let stock: Set<String> = ["trio", "swissalpine", "complication"]
precondition(names.isDisjoint(with: stock))
for old in GarminWatchface.allCases {
    for new in GarminWatchface.allCases {
        let expected = old != new && (stock.contains(old.rawValue) || stock.contains(new.rawValue))
        precondition(new.requiresTransmissionPause(from: old) == expected,
                     "Unexpected pause for \(old) -> \(new)")
    }
}
let available = Set(ids.map { $0.uuidString.replacingOccurrences(of: "-", with: "").uppercased() })
'''
for face, uuid in TARGETS.items():
    checks += f'precondition(available.contains("{uuid}"), "Missing {face}")\n'
checks += r'''
let encoder = JSONEncoder()
let decoder = JSONDecoder()
for face in GarminWatchface.allCases {
    for enabled in [false, true] {
        let settings = GarminWatchSettings(watchface: face, isWatchfaceDataEnabled: enabled)
        let restored = try decoder.decode(GarminWatchSettings.self, from: encoder.encode(settings))
        precondition(restored == settings, "Settings round-trip changed existing values")
    }
}
print("PASS: 16 retained targets, unique IDs, all selection transitions, settings round-trip")
'''
with tempfile.TemporaryDirectory(prefix="trio-routing-") as directory:
    swift = Path(directory) / "main.swift"
    swift.write_text("import Foundation\nprotocol JSON: Codable {}\n" + source + checks)
    executable = Path(directory) / "routing-tests"
    subprocess.run(["xcrun", "swiftc", str(swift), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
