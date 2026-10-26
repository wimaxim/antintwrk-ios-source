// Copyright 2026 Super David Universe LLC.
// SPDX-License-Identifier: AGPL-3.0-only

import Compound
import SwiftUI

struct AntintwrkWelcomeScreen: View {
    @Bindable var context: AntintwrkWelcomeScreenViewModel.Context
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Color(red: 0.059, green: 0.071, blue: 0.078).ignoresSafeArea()
                AntintwrkSignalArtwork(animated: true)
                    .frame(height: context.viewState.isLoading ? geometry.size.height : 260)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                ScrollView {
                    VStack(spacing: 24) {
                        Image("images/antintwrk-brand-mark")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 80, height: 80)
                            .accessibilityHidden(true)
                        wordmark
                        Text(AntintwrkStrings.value(context.viewState.isLoading ? "screen_antintwrk_loading" : "screen_antintwrk_welcome"))
                            .font(.compound.headingMDBold)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        if context.viewState.isLoading {
                            ProgressView().tint(.white)
                                .accessibilityLabel(AntintwrkStrings.value("screen_antintwrk_loading"))
                        } else {
                            welcomeActions
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 40)
                    .frame(maxWidth: 480)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
            }
        }
        .preferredColorScheme(.dark)
        .alert(item: $context.alertInfo)
    }
    
    private var wordmark: some View {
        HStack(spacing: 0) {
            Text("anti")
            Text("·").foregroundStyle(Color(red: 0.941, green: 0.42, blue: 0.333))
            Text("ntwrk")
        }
        .environment(\.layoutDirection, .leftToRight)
        .font(.system(size: 36, weight: .bold))
        .foregroundStyle(.white)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("ANTINTWRK")
    }
    
    private var welcomeActions: some View {
        VStack(spacing: 16) {
            Text(AntintwrkStrings.value("screen_antintwrk_intro"))
                .font(.compound.bodyMD)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
            Button(AntintwrkStrings.value("screen_antintwrk_register")) { context.send(viewAction: .register) }
                .buttonStyle(AntintwrkWelcomeButtonStyle(isPrimary: true))
                .accessibilityIdentifier("antintwrk-welcome-register")
            Button(AntintwrkStrings.value("screen_antintwrk_login")) { context.send(viewAction: .signIn) }
                .buttonStyle(AntintwrkWelcomeButtonStyle(isPrimary: false))
                .accessibilityIdentifier("antintwrk-welcome-sign-in")
            if context.viewState.isPreview {
                Text(AntintwrkStrings.value("screen_antintwrk_preview"))
                    .font(.compound.bodySM)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        }
    }
}

private struct AntintwrkWelcomeButtonStyle: ButtonStyle {
    let isPrimary: Bool
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.compound.bodyLGSemibold)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .foregroundStyle(isPrimary ? Color.black : .white)
            .background(isPrimary ? Color(red: 0.941, green: 0.42, blue: 0.333) : Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(isPrimary ? 0 : 0.25)))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct AntintwrkWelcomeScreen_Previews: PreviewProvider, TestablePreview {
    static let welcomeViewModel = AntintwrkWelcomeScreenViewModel(isPreview: true)
    static let loadingViewModel = AntintwrkWelcomeScreenViewModel(isLoading: true)
    
    static var previews: some View {
        AntintwrkWelcomeScreen(context: welcomeViewModel.context)
        AntintwrkWelcomeScreen(context: loadingViewModel.context)
    }
}
