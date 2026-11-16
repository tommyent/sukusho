// Puts a sample string on the general pasteboard from a process that isn't the
// probe app, as another app's copy would be. Kept on this Mac (no Universal
// Clipboard) and marked transient, so clipboard histories skip it.
import AppKit

let sample = CommandLine.arguments.dropFirst().first ?? "sukusho-probe-sample"
let pasteboard = NSPasteboard.general
pasteboard.prepareForNewContents(with: .currentHostOnly)
let item = NSPasteboardItem()
item.setString(sample, forType: .string)
item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
item.setData(Data(), forType: NSPasteboard.PasteboardType("com.tommyent.Sukusho.probe-sample"))
pasteboard.writeObjects([item])
print(pasteboard.changeCount)
