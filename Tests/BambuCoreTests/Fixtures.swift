import Foundation
@testable import BambuCore

/// Shaped like a P1S pushall answer (trimmed).
let pushall: JSON = [
    "print": [
        "command": "push_status",
        "gcode_state": "RUNNING",
        "mc_percent": 37,
        "mc_remaining_time": 52,
        "layer_num": 88,
        "total_layer_num": 240,
        "nozzle_temper": 219.8,
        "nozzle_target_temper": 220,
        "bed_temper": 54.9,
        "bed_target_temper": 55,
        "cooling_fan_speed": "15",
        "big_fan1_speed": "0",
        "big_fan2_speed": "10",
        "subtask_name": "Cable clip",
        "gcode_file": "/data/Metadata/plate_1.gcode",
        "task_id": "412345678",
        "print_error": 0,
        "wifi_signal": "-52dBm",
        "ams": [
            "tray_now": "1",
            "ams": [
                [
                    "id": "0",
                    "tray": [
                        ["id": "0", "tray_type": "PLA", "tray_color": "FFFFFFFF"],
                        ["id": "1", "tray_type": "PETG", "tray_color": "00AE42FF"],
                    ],
                ],
            ],
        ],
        "vt_tray": ["id": "254", "tray_type": "ABS", "tray_color": "000000FF"],
    ],
]

func details(_ state: String, material: String = "ABS") -> PrinterDetails {
    toPrinterDetails([
        "print": [
            "gcode_state": .string(state),
            "subtask_name": "lid.3mf",
            "ams": ["tray_now": "254"],
            "vt_tray": ["tray_type": .string(material)],
        ],
    ])
}
