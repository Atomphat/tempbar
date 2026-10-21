// เครื่องมืออัดภาพสำหรับ README
//   swiftc tools/demo.swift -o build/demo
//   build/demo post menu|close|touchbar        สั่ง TempBar ที่เปิดอยู่
//   build/demo windows                         window id ของ TempBar (สำหรับ screencapture -l)
//   build/demo gif out.gif delay a.png b.png…  รวมภาพเป็น GIF เคลื่อนไหว
import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "post" where args.count == 3:
    DistributedNotificationCenter.default().postNotificationName(
        .init("com.atom.tempbar.demo.\(args[2])"), object: nil, userInfo: nil, deliverImmediately: true)
case "windows":
    // window id ของ TempBar ที่มองเห็นอยู่ (ใช้กับ screencapture -l)
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in list where w[kCGWindowOwnerName as String] as? String == "TempBar" {
        let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        print(w[kCGWindowNumber as String]!, w[kCGWindowLayer as String]!, b["X"]!, b["Y"]!, b["Width"]!, b["Height"]!)
    }
case "gif" where args.count > 4:
    let out = URL(fileURLWithPath: args[2]) as CFURL
    let delay = Double(args[3]) ?? 1
    let frames = args[4...]
    guard let dest = CGImageDestinationCreateWithURL(out, UTType.gif.identifier as CFString, frames.count, nil) else { exit(1) }
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for f in frames {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: f) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
        CGImageDestinationAddImage(dest, img, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
    }
    exit(CGImageDestinationFinalize(dest) ? 0 : 1)
default:
    print("ใช้: demo post <menu|close|touchbar> | demo gif <out.gif> <delay> <frames…>")
    exit(1)
}
