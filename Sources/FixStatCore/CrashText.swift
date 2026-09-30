import Foundation
import MacSensors

public enum CrashText {
    public static func shutdownMeaning(_ id: String?) -> String {
        switch id {
        case "normal": L("Normal shutdown")
        case "hardShutdown": L("Power button held (forced shutdown)")
        case "powerLoss": L("Power lost")
        case "overTemperature": L("Temperature limit exceeded (several sensors)")
        case "batteryEmpty": L("Battery empty")
        case "smcWatchdog": L("SMC / power management watchdog")
        case "watchdog": L("Watchdog — often logic board or RAM")
        case "memoryTemperature": L("Memory temperature limit exceeded")
        case "batteryTemperature": L("Battery temperature limit exceeded")
        case "adapterCommunication": L("Communication problem with the power adapter")
        case "adapterCurrent": L("Wrong current from the power adapter")
        case "batteryCurrent": L("Wrong current from the battery")
        case "proximityTemperature": L("Proximity sensor temperature exceeded")
        case "cpuTemperature": L("CPU temperature limit exceeded")
        case "powerSupplyTemperature": L("Power supply temperature exceeded")
        case "batteryCellVoltage": L("Battery cell under-voltage")
        case "battery": L("Battery problem")
        case "pmuForced": L("Forced shutdown by the PMU")
        case "unknownCritical": L("Unknown critical shutdown — often logic board")
        default: L("Unknown code")
        }
    }

    public static func area(_ id: String) -> String {
        switch id {
        case "smc": L("SMC")
        case "aop": L("Always-On Processor")
        case "thermal": L("Thermal monitor")
        case "sleepwake": L("Sleep / wake")
        case "watchdog": L("Watchdog")
        case "ssd": L("SSD controller")
        case "display": L("Display")
        case "gpu": L("GPU")
        case "i2c": L("I2C bus")
        case "power": L("Power management")
        case "usb": L("USB-C / ports")
        case "wireless": L("Wi-Fi / Bluetooth")
        default: id
        }
    }
}
