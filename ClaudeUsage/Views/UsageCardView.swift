import SwiftUI

extension UsageStatusLevel {
    var color: Color {
        switch self {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

struct UsageCardView: View {
    let item: UsageItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Title row with reset time
            HStack(alignment: .firstTextBaseline) {
                Text(item.displayTitle)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                Spacer()

                // At limit: show static target time (doesn't need timer updates)
                // Normal: show "14:30 · in 2h 30m" or "Ready"
                if item.isAtLimit, let target = item.resetTimeTarget {
                    Text(target)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else if let resetTime = item.useLongResetDisplay ? item.resetTimeDisplayLong : item.resetTimeDisplay {
                    Text(resetTime)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else {
                    Text(item.resetTimeRemaining ?? "Ready")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            // Usage percentage and progress bar
            HStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(item.utilization)")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundColor(item.statusLevel.color)

                    Text("%")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(item.statusLevel.color)
                }
                .fixedSize()

                // Progress bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(Color(nsColor: .separatorColor))

                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(item.statusLevel.color)
                            .frame(width: geometry.size.width * min(item.percentage, 1.0))
                    }
                }
                .frame(height: 6)
            }

        }
        .padding(10)
        .background(Constants.Colors.cardBackground)
        .cornerRadius(6)
    }
}

/// Compact version for grid layout (2 per row)
struct UsageCardCompactView: View {
    let item: UsageItem

    var body: some View {
        HStack(spacing: 8) {
            // Circular progress indicator
            ZStack {
                Circle()
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 3)

                Circle()
                    .trim(from: 0, to: min(item.percentage, 1.0))
                    .stroke(item.statusLevel.color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                // Title (shortened)
                Text(item.compactTitle)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                // Percentage and reset time
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(item.utilization)")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundColor(item.statusLevel.color)

                        Text("%")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(item.statusLevel.color)
                    }

                    if let remaining = item.isAtLimit ? item.resetTimeTarget : item.resetTimeRemaining {
                        Text(remaining)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Constants.Colors.cardBackground)
        .cornerRadius(6)
    }
}


