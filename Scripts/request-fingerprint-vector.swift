#!/usr/bin/env swift
import CryptoKit
import Foundation

func u32(_ value: Int) -> [UInt8] { [UInt8(value >> 24), UInt8(value >> 16), UInt8(value >> 8), UInt8(value)] }
func field(_ bytes: [UInt8]?) -> [UInt8] { guard let bytes else { return [255, 255, 255, 255] }; return u32(bytes.count) + bytes }
func utf8(_ value: String) -> [UInt8] { Array(value.utf8) }
func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

let controls = utf8("ALCTRL01") + u32(5) + utf8("speed") + u32(1) + utf8("0")
let normalizedText = "A\u{030A}!".precomposedStringWithCanonicalMapping
let digest = Array(SHA256.hash(data: Data(normalizedText.utf8)))
let fields: [[UInt8]?] = [
    utf8("openai"), [0x00,0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88,0x99,0xaa,0xbb,0xcc,0xdd,0xee,0xff],
    utf8("31"), utf8("gpt-4o-mini-tts"), utf8("alloy"), digest, controls,
    utf8("rate-v1"), nil, utf8("wav-v1"), utf8("nfc-utf8-v1|canonical-v1")
]
let wire = utf8("ALRFP001") + [0, 1] + fields.flatMap(field)
print(hex(wire))
print(hex(Array(SHA256.hash(data: Data(wire)))))
