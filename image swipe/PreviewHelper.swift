import SwiftUI

// MARK: - Preview Helper

struct ContentViewPreview: View {
    var body: some View {
        VStack {
            Text("Image Swipe App")
                .font(.largeTitle)
                .foregroundStyle(.white)
                .padding()
            
            // Имитация карточки фото
            RoundedRectangle(cornerRadius: 20)
                .fill(.gray.opacity(0.3))
                .frame(width: 300, height: 400)
                .overlay(
                    VStack {
                        Image(systemName: "photo.fill")
                            .font(.system(size: 80))
                            .foregroundStyle(.white.opacity(0.7))
                        Text("Фото будет здесь")
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(.top, 10)
                    }
                )
                .padding()
            
            // Кнопки действий
            HStack(spacing: 40) {
                Button(action: {}) {
                    Image(systemName: "xmark")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                        .frame(width: 60, height: 60)
                        .background(
                            Circle()
                                .fill(.red)
                                .shadow(color: .red.opacity(0.4), radius: 12, y: 6)
                        )
                }
                
                Button(action: {}) {
                    Image(systemName: "heart.fill")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                        .frame(width: 60, height: 60)
                        .background(
                            Circle()
                                .fill(.green)
                                .shadow(color: .green.opacity(0.4), radius: 12, y: 6)
                        )
                }
            }
            .padding()
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [.black, .gray.opacity(0.8)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .ignoresSafeArea()
    }
}

#Preview {
    ContentViewPreview()
} 