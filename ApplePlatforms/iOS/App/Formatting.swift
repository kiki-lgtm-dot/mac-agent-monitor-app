import Foundation

enum DashboardFormatting {
  static func tokens(_ value: UInt64) -> String {
    let scale: Double
    let suffix: String

    switch value {
    case 1_000_000_000...:
      scale = 1_000_000_000
      suffix = "B"
    case 1_000_000...:
      scale = 1_000_000
      suffix = "M"
    case 1_000...:
      scale = 1_000
      suffix = "K"
    default:
      return value.formatted()
    }

    let number = Double(value) / scale
    let precision = number >= 100 ? 0 : 1
    return number.formatted(.number.precision(.fractionLength(precision))) + suffix
  }

  static func duration(_ seconds: UInt64) -> String {
    if seconds == 0 { return "—" }
    let hours = seconds / 3_600
    let minutes = (seconds % 3_600) / 60

    if hours > 0 {
      let format = NSLocalizedString("duration.hours_minutes", comment: "")
      return String.localizedStringWithFormat(format, hours, minutes)
    }

    let format = NSLocalizedString("duration.minutes", comment: "")
    return String.localizedStringWithFormat(format, max(1, minutes))
  }
}
