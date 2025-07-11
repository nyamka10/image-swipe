import SwiftUI

// MARK: - Простой Preview без сложной логики

struct SimpleAppPreview: View {
    var body: some View {
        Text("Image Swipe App Works! 🎉")
            .font(.title)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
    }
}

#Preview {
    SimpleAppPreview()
} 