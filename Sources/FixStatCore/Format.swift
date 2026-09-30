import Foundation

/// Locale-aware formatting of all numbers shown in the UI (both interfaces).
///
/// macOS 12 / 13 and later use FormatStyle and Duration exactly as before; older systems
/// fall back to NumberFormatter, MeasurementFormatter, ByteCountFormatter and
/// DateComponentsFormatter with the same precision. Formatting follows the user's region.
public enum Format {
    /// Tests only: take the pre-macOS 12 code paths on a new system.
    public nonisolated(unsafe) static var forceLegacy = false

    public static func percent(_ value: Double, digits: Int = 0) -> String {
        if #available(macOS 12, *), !forceLegacy {
            return (value / 100).formatted(.percent.precision(.fractionLength(digits)))
        }
        let f = NumberFormatter()
        f.numberStyle = .percent
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        return f.string(from: NSNumber(value: value / 100)) ?? ""
    }

    /// "58.4 °C" style (unit shown).
    public static func temperature(_ celsius: Double, digits: Int = 1) -> String {
        if #available(macOS 12, *), !forceLegacy {
            return Measurement(value: celsius, unit: UnitTemperature.celsius)
                .formatted(.measurement(width: .narrow, usage: .asProvided,
                                        numberFormatStyle: .number.precision(.fractionLength(digits))))
        }
        return measurement(Measurement(value: celsius, unit: UnitTemperature.celsius), digits: digits, style: .short)
    }

    /// "58°" style for compact places (menu bar, sensor rows).
    public static func degrees(_ celsius: Double, digits: Int = 0) -> String {
        L("%@°", number(celsius, digits: digits))
    }

    public static func milliampHours(_ value: Int) -> String {
        if #available(macOS 12, *), !forceLegacy {
            return Measurement(value: Double(value), unit: UnitElectricCharge.milliampereHours)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided))
        }
        return measurement(Measurement(value: Double(value), unit: UnitElectricCharge.milliampereHours), digits: 0)
    }

    public static func milliamps(_ value: Int, signed: Bool = true) -> String {
        if #available(macOS 12, *), !forceLegacy {
            let style: FloatingPointFormatStyle<Double> = signed ? .number.sign(strategy: .always(includingZero: false)) : .number
            return Measurement(value: Double(value), unit: UnitElectricCurrent.milliamperes)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: style))
        }
        let text = measurement(Measurement(value: Double(value), unit: UnitElectricCurrent.milliamperes), digits: 0)
        return signed && value > 0 ? "+" + text : text
    }

    public static func volts(millivolts: Int, digits: Int = 2) -> String {
        if #available(macOS 12, *), !forceLegacy {
            return Measurement(value: Double(millivolts) / 1000, unit: UnitElectricPotentialDifference.volts)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                        numberFormatStyle: .number.precision(.fractionLength(digits))))
        }
        return measurement(Measurement(value: Double(millivolts) / 1000, unit: UnitElectricPotentialDifference.volts),
                           digits: digits)
    }

    public static func amps(milliamps: Int) -> String {
        let digits = milliamps % 1000 == 0 ? 0 : (milliamps % 100 == 0 ? 1 : 2)
        if #available(macOS 12, *), !forceLegacy {
            return Measurement(value: Double(milliamps) / 1000, unit: UnitElectricCurrent.amperes)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                        numberFormatStyle: .number.precision(.fractionLength(digits))))
        }
        return measurement(Measurement(value: Double(milliamps) / 1000, unit: UnitElectricCurrent.amperes), digits: digits)
    }

    public static func millivolts(_ value: Int) -> String {
        if #available(macOS 12, *), !forceLegacy {
            return Measurement(value: Double(value), unit: UnitElectricPotentialDifference.millivolts)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided))
        }
        return measurement(Measurement(value: Double(value), unit: UnitElectricPotentialDifference.millivolts), digits: 0)
    }

    public static func watts(_ value: Double, digits: Int = 0) -> String {
        if #available(macOS 12, *), !forceLegacy {
            return Measurement(value: value, unit: UnitPower.watts)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                        numberFormatStyle: .number.precision(.fractionLength(digits))))
        }
        return measurement(Measurement(value: value, unit: UnitPower.watts), digits: digits)
    }

    public static func minutes(_ minutes: Int) -> String {
        if #available(macOS 13, *), !forceLegacy {
            return Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        }
        return components(Double(minutes * 60), units: [.hour, .minute], maximum: 2)
    }

    public static let wattHourUnit = UnitEnergy(symbol: "Wh", converter: UnitConverterLinear(coefficient: 3600))

    /// "24.5 Wh"
    public static func watthours(_ value: Double) -> String {
        if #available(macOS 12, *), !forceLegacy {
            return Measurement(value: value, unit: wattHourUnit)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                        numberFormatStyle: .number.precision(.fractionLength(1))))
        }
        return measurement(Measurement(value: value, unit: wattHourUnit), digits: 1)
    }

    /// "3 h 12 min", "45 s": days / hours / minutes / seconds, largest two units.
    public static func duration(_ seconds: Double) -> String {
        if #available(macOS 13, *), !forceLegacy {
            return Duration.seconds(seconds.rounded()).formatted(.units(allowed: [.days, .hours, .minutes, .seconds],
                                                                        width: .abbreviated, maximumUnitCount: 2))
        }
        return components(seconds.rounded(), units: [.day, .hour, .minute, .second], maximum: 2)
    }

    /// "3.2 s"
    public static func seconds(_ value: Double) -> String {
        if #available(macOS 12, *), !forceLegacy {
            return Measurement(value: value, unit: UnitDuration.seconds)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                        numberFormatStyle: .number.precision(.fractionLength(1))))
        }
        return measurement(Measurement(value: value, unit: UnitDuration.seconds), digits: 1)
    }

    /// "4:05" style minutes and seconds.
    public static func minutesSeconds(_ seconds: TimeInterval) -> String {
        if #available(macOS 13, *), !forceLegacy {
            return Duration.seconds(seconds.rounded()).formatted(.time(pattern: .minuteSecond))
        }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    public static func gigabytes(_ bytes: UInt64, digits: Int = 1) -> String {
        if #available(macOS 12, *), !forceLegacy {
            return Measurement(value: Double(bytes) / 1_073_741_824, unit: UnitInformationStorage.gigabytes)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                        numberFormatStyle: .number.precision(.fractionLength(digits))))
        }
        guard #available(macOS 10.15, *) else { return number(Double(bytes) / 1_073_741_824, digits: digits) + " GB" }
        return measurement(Measurement(value: Double(bytes) / 1_073_741_824, unit: UnitInformationStorage.gigabytes),
                           digits: digits)
    }

    /// Decimal byte count ("256 GB", "23,6 TB"), like Finder.
    public static func bytes(_ value: Double) -> String {
        if #available(macOS 12, *), !forceLegacy {
            return Int64(value).formatted(.byteCount(style: .decimal))
        }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .decimal)
    }

    /// Installed memory in binary units ("8 GB" for 8 GiB), like "About This Mac".
    public static func memory(_ bytes: UInt64) -> String {
        if #available(macOS 12, *), !forceLegacy {
            return Int64(bytes).formatted(.byteCount(style: .memory))
        }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    public static func speed(megabytesPerSecond: Double) -> String {
        let size: String
        if #available(macOS 12, *), !forceLegacy {
            size = Measurement(value: megabytesPerSecond, unit: UnitInformationStorage.megabytes)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                        numberFormatStyle: .number.precision(.fractionLength(0))))
        } else if #available(macOS 10.15, *) {
            size = measurement(Measurement(value: megabytesPerSecond, unit: UnitInformationStorage.megabytes), digits: 0)
        } else {
            size = number(megabytesPerSecond) + " MB"
        }
        return size + L("/s")
    }

    public static func number(_ value: Double, digits: Int = 0) -> String {
        if #available(macOS 12, *), !forceLegacy {
            return value.formatted(.number.precision(.fractionLength(digits)))
        }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        return f.string(from: NSNumber(value: value)) ?? ""
    }

    /// Signal or level in decibels, e.g. "−47 dBm", "−12 dBFS".
    public static func decibels(_ value: Double, unit: String) -> String {
        number(value) + "\u{00A0}" + unit
    }

    public static func rpm(_ value: Double) -> String {
        L("%@ rpm", number(value))
    }

    // MARK: Fallbacks for macOS 10.13 – 11

    private static func measurement<U: Unit>(_ value: Measurement<U>, digits: Int,
                                             style: Formatter.UnitStyle = .medium) -> String {
        let f = MeasurementFormatter()
        f.unitOptions = .providedUnit
        f.unitStyle = style
        f.numberFormatter.minimumFractionDigits = digits
        f.numberFormatter.maximumFractionDigits = digits
        return f.string(from: value)
    }

    private static func components(_ seconds: Double, units: NSCalendar.Unit, maximum: Int) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = units
        f.unitsStyle = .short
        f.maximumUnitCount = maximum
        return f.string(from: seconds) ?? ""
    }
}
