import SwiftUI

// MARK: - Model Profile Row

struct ModelProfileRow: View {
    let profile: ModelProfile
    let isDefaultSTT: Bool
    let isDefaultLLM: Bool
    let amber: Color
    let green: Color
    let textPrimary: Color
    let textDim: Color
    let cardBg: Color
    let separator: Color
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Provider icon
                providerIcon(for: profile.provider)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name)
                        .foregroundColor(textPrimary)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .truncationMode(.tail)

                    HStack(spacing: 6) {
                        Text("\(providerDisplayName(profile.provider)) · \(profile.modelID)")
                            .font(.system(size: 12))
                            .foregroundColor(textDim)
                    }

                    // Capability badges + default badges
                    HStack(spacing: 6) {
                        if profile.hasSTT {
                            badgeView("STT", color: amber)
                        }
                        if profile.hasLLM {
                            badgeView("LLM", color: green)
                        }
                        if isDefaultSTT {
                            badgeView("Default STT", color: amber.opacity(0.6))
                        }
                        if isDefaultLLM {
                            badgeView("Default LLM", color: green.opacity(0.6))
                        }
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(textDim)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(PlainButtonStyle())
        .listRowBackground(cardBg)
        .listRowSeparatorTint(separator)
    }

    private func badgeView(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.opacity(0.12))
            )
    }

    private func providerIcon(for provider: String) -> some View {
        let (icon, color): (String, Color) = {
            switch provider {
            case "openai":    return ("brain", amber)
            case "anthropic": return ("sparkle", Color(hex: "#c084fc"))
            case "google":    return ("magnifyingglass.circle", Color(hex: "#60a5fa"))
            case "ollama":    return ("server.rack", green)
            case "lmstudio":  return ("laptopcomputer", green)
            case "omlx":      return ("apple.terminal", Color(hex: "#60a5fa"))
            default:          return ("network", textDim)
            }
        }()
        return Image(systemName: icon)
            .foregroundColor(color)
    }

    private func providerDisplayName(_ provider: String) -> String {
        switch provider {
        case "openai":    return "OpenAI"
        case "openrouter": return "OpenRouter"
        case "anthropic": return "Anthropic"
        case "google":    return "Google"
        case "ollama":    return "Ollama"
        case "lmstudio":  return "LM Studio"
        case "omlx":      return "OMLX"
        case "custom":    return "Custom"
        default:          return provider.capitalized
        }
    }
}
