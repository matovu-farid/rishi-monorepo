//
//  ErrorView.swift
//  rishi
//
//  Created by Farid Matovu on 03/07/2026.
//




import SwiftUI

struct ErrorView: View {
    let error: LocalizedError
    let retryAction: () -> Void 
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "extech.triangle.fill")
                .font(.system(size: 50))
                .foregroundColor(.red)
            
            Text(error.errorDescription ?? "An Error Occurred")
                .font(.title3)
                .bold()
            
            if let suggestion = error.recoverySuggestion {
                Text(suggestion)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            
            Button(action: retryAction) {
                Text("Try Again")
                    .bold()
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .padding(.horizontal, 40)
        }
        .padding()
    }
}

