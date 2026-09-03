#if os(iOS) && canImport(ActivityKit)
  import ActivityKit
  import SwiftUI
  import WidgetKit

  @available(iOSApplicationExtension 16.2, *)
  struct AgentIslandLiveActivity: Widget {
    var body: some WidgetConfiguration {
      ActivityConfiguration(for: AgentIslandActivityAttributes.self) { context in
        LockScreenAgentView(state: context.state, isStale: context.isStale)
          .activityBackgroundTint(Color.black.opacity(0.92))
          .activitySystemActionForegroundColor(.white)
          .widgetURL(URL(string: "agentisland://dashboard"))
      } dynamicIsland: { context in
        DynamicIsland {
          DynamicIslandExpandedRegion(.leading) {
            LiveMetric(
              icon: "cpu.fill",
              value: context.state.runningAgentCount.formatted(),
              labelKey: "widget.agent_short"
            )
          }

          DynamicIslandExpandedRegion(.trailing) {
            LiveMetric(
              icon: "number",
              value: WidgetFormatting.tokens(context.state.totalTokens),
              labelKey: "widget.token_short",
              alignment: .trailing
            )
          }

          DynamicIslandExpandedRegion(.center) {
            HStack(spacing: 7) {
              Circle()
                .fill(statusColor(state: context.state, isStale: context.isStale))
                .frame(width: 8, height: 8)
              if context.state.isExampleData == true {
                Text("widget.example_short")
                  .font(.caption2.bold())
                  .foregroundStyle(.orange)
              }
              Text(statusLabel(state: context.state, isStale: context.isStale))
                .font(.headline)
            }
          }

          DynamicIslandExpandedRegion(.bottom) {
            HStack(spacing: 12) {
              Label {
                Text(context.state.activeConversationCount.formatted())
              } icon: {
                Image(systemName: "bubble.left.and.bubble.right.fill")
              }

              Spacer()

              Label {
                Text(WidgetFormatting.duration(context.state.activeDurationSeconds))
              } icon: {
                Image(systemName: "timer")
              }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
          }
        } compactLeading: {
          HStack(spacing: 4) {
            Image(systemName: context.state.isExampleData == true ? "testtube.2" : "cpu.fill")
              .foregroundStyle(statusColor(state: context.state, isStale: context.isStale))
            Text(context.state.runningAgentCount.formatted())
              .font(.caption.bold())
          }
        } compactTrailing: {
          Text(WidgetFormatting.tokens(context.state.totalTokens))
            .font(.caption.monospacedDigit().bold())
            .foregroundStyle(.mint)
        } minimal: {
          ZStack {
            Circle().fill(
              statusColor(state: context.state, isStale: context.isStale).opacity(0.18)
            )
            if context.state.isExampleData == true {
              Image(systemName: "testtube.2")
                .font(.caption2.bold())
                .foregroundStyle(statusColor(state: context.state, isStale: context.isStale))
            } else {
              Text(context.state.runningAgentCount.formatted())
                .font(.caption2.bold())
                .foregroundStyle(statusColor(state: context.state, isStale: context.isStale))
            }
          }
        }
        .keylineTint(.mint)
        .widgetURL(URL(string: "agentisland://dashboard"))
      }
    }
  }

  @available(iOSApplicationExtension 16.2, *)
  private struct LockScreenAgentView: View {
    let state: AgentIslandActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
      HStack(spacing: 14) {
        ZStack {
          RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(statusColor(state: state, isStale: isStale).opacity(0.16))
          Image(systemName: "cpu.fill")
            .foregroundStyle(statusColor(state: state, isStale: isStale))
            .font(.title3)
        }
        .frame(width: 46, height: 46)

        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 6) {
            Circle()
              .fill(statusColor(state: state, isStale: isStale))
              .frame(width: 7, height: 7)
            Text(statusLabel(state: state, isStale: isStale))
              .font(.headline)
          }

          Text(
            LocalizedStringKey(
              state.isExampleData == true
                ? "widget.example_summary"
                : "widget.privacy_summary"
            )
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        }

        Spacer(minLength: 10)

        VStack(alignment: .trailing, spacing: 4) {
          Text(WidgetFormatting.tokens(state.totalTokens))
            .font(.system(.title3, design: .rounded, weight: .bold))
            .foregroundStyle(.mint)
          Text(WidgetFormatting.duration(state.activeDurationSeconds))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 13)
    }
  }

  private func statusColor(
    state: AgentIslandActivityAttributes.ContentState,
    isStale: Bool
  ) -> Color {
    if isStale { return .orange }
    if state.isExampleData == true { return .purple }
    return state.status == .working ? .green : .secondary
  }

  private func statusLabel(
    state: AgentIslandActivityAttributes.ContentState,
    isStale: Bool
  ) -> LocalizedStringKey {
    LocalizedStringKey(isStale ? "state.stale" : state.status.localizationKey)
  }

  private struct LiveMetric: View {
    let icon: String
    let value: String
    let labelKey: LocalizedStringKey
    var alignment: HorizontalAlignment = .leading

    var body: some View {
      VStack(alignment: alignment, spacing: 2) {
        HStack(spacing: 5) {
          Image(systemName: icon)
            .foregroundStyle(.mint)
          Text(value)
            .font(.system(.body, design: .rounded, weight: .bold))
            .monospacedDigit()
        }
        Text(labelKey)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
  }

  private enum WidgetFormatting {
    static func tokens(_ value: UInt64) -> String {
      switch value {
      case 1_000_000_000...:
        return compact(value, scale: 1_000_000_000, suffix: "B")
      case 1_000_000...:
        return compact(value, scale: 1_000_000, suffix: "M")
      case 1_000...:
        return compact(value, scale: 1_000, suffix: "K")
      default:
        return value.formatted()
      }
    }

    static func duration(_ seconds: UInt64) -> String {
      if seconds == 0 { return "—" }
      let hours = seconds / 3_600
      let minutes = (seconds % 3_600) / 60
      if hours > 0 { return "\(hours)h \(minutes)m" }
      return "\(max(1, minutes))m"
    }

    private static func compact(_ value: UInt64, scale: Double, suffix: String) -> String {
      let number = Double(value) / scale
      let precision = number >= 100 ? 0 : 1
      return number.formatted(.number.precision(.fractionLength(precision))) + suffix
    }
  }

  extension LiveAgentStatus {
    fileprivate var localizationKey: String {
      switch self {
      case .working: return "state.working"
      case .idle: return "state.idle"
      }
    }
  }
#endif
