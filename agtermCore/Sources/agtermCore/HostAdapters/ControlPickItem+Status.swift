extension ControlPickItem {
    /// statusError rejects an unknown status, color or shape before a host draws the row; it never echoes the
    /// caller's value. `pick.open` validates through it too, so a host-built picker applies the same rule.
    public var statusError: String? {
        if let status, AgentStatus(rawValue: status) == nil {
            return "invalid pick item status (\(AgentStatus.allCases.map(\.rawValue).joined(separator: "|")))"
        }
        if let statusColor, !WatermarkConfig.isValidColorHex(statusColor) {
            return "invalid pick item color (expected #rrggbb)"
        }
        if let statusShape, StatusShape(rawValue: statusShape) == nil {
            return "invalid pick item shape (\(StatusShape.validNamesList))"
        }
        return nil
    }
}
