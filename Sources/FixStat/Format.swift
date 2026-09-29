import Foundation

/// Locale-aware formatting of all numbers shown in the UI.
enum Format {
    static func percent(_ value: Double, digits: Int = 0) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(digits)))
    }

    /// "58.4 °C" style (unit shown).
    static func temperature(_ celsius: Double, digits: Int = 1) -> String {
        Measurement(value: celsius, unit: UnitTemperature.celsius)
            .formatted(.measurement(width: .narrow, usage: .asProvided,
                                    numberFormatStyle: .number.precision(.fractionLength(digits))))
    }

    /// "58°" style for compact places (menu bar, sensor rows).
    static func degrees(_ celsius: Double, digits: Int = 0) -> String {
        let number = celsius.formatted(.number.precision(.fractionLength(digits)))
        return String(localized: "\(number)°", comment: "Compact temperature, e.g. 58°")
    }

    static func milliampHours(_ value: Int) -> String {
        Measurement(value: Double(value), unit: UnitElectricCharge.milliampereHours)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided))
    }

    static func milliamps(_ value: Int, signed: Bool = true) -> String {
        let style: FloatingPointFormatStyle<Double> = signed ? .number.sign(strategy: .always(includingZero: false)) : .number
        return Measurement(value: Double(value), unit: UnitElectricCurrent.milliamperes)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: style))
    }

    static func volts(millivolts: Int, digits: Int = 2) -> String {
        Measurement(value: Double(millivolts) / 1000, unit: UnitElectricPotentialDifference.volts)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                    numberFormatStyle: .number.precision(.fractionLength(digits))))
    }

    static func amps(milliamps: Int) -> String {
        let digits = milliamps % 1000 == 0 ? 0 : (milliamps % 100 == 0 ? 1 : 2)
        return Measurement(value: Double(milliamps) / 1000, unit: UnitElectricCurrent.amperes)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                    numberFormatStyle: .number.precision(.fractionLength(digits))))
    }

    static func millivolts(_ value: Int) -> String {
        Measurement(value: Double(value), unit: UnitElectricPotentialDifference.millivolts)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided))
    }

    static func watts(_ value: Double, digits: Int = 0) -> String {
        Measurement(value: value, unit: UnitPower.watts)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                    numberFormatStyle: .number.precision(.fractionLength(digits))))
    }

    static func minutes(_ minutes: Int) -> String {
        Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    static let wattHourUnit = UnitEnergy(symbol: "Wh", converter: UnitConverterLinear(coefficient: 3600))

    /// "24.5 Wh"
    static func watthours(_ value: Double) -> String {
        Measurement(value: value, unit: wattHourUnit)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                    numberFormatStyle: .number.precision(.fractionLength(1))))
    }

    /// "3 h 12 min", "45 s": days / hours / minutes / seconds, largest two units.
    static func duration(_ seconds: Double) -> String {
        Duration.seconds(seconds.rounded()).formatted(.units(allowed: [.days, .hours, .minutes, .seconds],
                                                             width: .abbreviated, maximumUnitCount: 2))
    }

    /// "3.2 s"
    static func seconds(_ value: Double) -> String {
        Measurement(value: value, unit: UnitDuration.seconds)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                    numberFormatStyle: .number.precision(.fractionLength(1))))
    }

    /// "4:05" style minutes and seconds.
    static func minutesSeconds(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.rounded()).formatted(.time(pattern: .minuteSecond))
    }

    static func gigabytes(_ bytes: UInt64, digits: Int = 1) -> String {
        Measurement(value: Double(bytes) / 1_073_741_824, unit: UnitInformationStorage.gigabytes)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                    numberFormatStyle: .number.precision(.fractionLength(digits))))
    }

    /// Decimal byte count ("256 GB", "23,6 TB"), like Finder.
    static func bytes(_ value: Double) -> String {
        Int64(value).formatted(.byteCount(style: .decimal))
    }

    /// Installed memory in binary units ("8 GB" for 8 GiB), like "About This Mac".
    static func memory(_ bytes: UInt64) -> String {
        Int64(bytes).formatted(.byteCount(style: .memory))
    }

    static func speed(megabytesPerSecond: Double) -> String {
        Measurement(value: megabytesPerSecond, unit: UnitInformationStorage.megabytes)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                    numberFormatStyle: .number.precision(.fractionLength(0))))
            + String(localized: "/s", comment: "per second, after a data size")
    }

    static func number(_ value: Double, digits: Int = 0) -> String {
        value.formatted(.number.precision(.fractionLength(digits)))
    }

    /// Signal or level in decibels, e.g. "−47 dBm", "−12 dBFS".
    static func decibels(_ value: Double, unit: String) -> String {
        value.formatted(.number.precision(.fractionLength(0))) + "\u{00A0}" + unit
    }

    static func rpm(_ value: Double) -> String {
        let number = value.formatted(.number.precision(.fractionLength(0)))
        return String(localized: "\(number) rpm", comment: "Fan speed")
    }
}
