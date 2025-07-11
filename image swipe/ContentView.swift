//
//  ContentView.swift
//  image swipe
//
//  Created by kmakarov on 10.07.2025.
//

import SwiftUI
import Photos
import PhotosUI
import CoreLocation

// MARK: - Progress Manager

@MainActor
class ProgressManager: ObservableObject {
    private let userDefaults = UserDefaults.standard
    
    private enum Keys {
        static let currentPhotoIndex = "currentPhotoIndex"
        static let totalPhotosCount = "totalPhotosCount"
        static let sortedPhotosCount = "sortedPhotosCount"
        static let lastSortingSession = "lastSortingSession"
    }
    
    @Published var currentPhotoIndex: Int = 0
    @Published var totalPhotosCount: Int = 0
    @Published var sortedPhotosCount: Int = 0
    
    var hasProgress: Bool {
        currentPhotoIndex > 0 && totalPhotosCount > 0
    }
    
    var progressPercentage: Double {
        guard totalPhotosCount > 0 else { return 0 }
        return Double(currentPhotoIndex) / Double(totalPhotosCount) * 100
    }
    
    var remainingCount: Int {
        max(0, totalPhotosCount - currentPhotoIndex)
    }
    
    init() {
        loadProgress()
    }
    
    func loadProgress() {
        currentPhotoIndex = userDefaults.integer(forKey: Keys.currentPhotoIndex)
        totalPhotosCount = userDefaults.integer(forKey: Keys.totalPhotosCount)
        sortedPhotosCount = userDefaults.integer(forKey: Keys.sortedPhotosCount)
    }
    
    func saveProgress(currentIndex: Int, totalCount: Int, sortedCount: Int) {
        currentPhotoIndex = currentIndex
        totalPhotosCount = totalCount
        sortedPhotosCount = sortedCount
        
        userDefaults.set(currentIndex, forKey: Keys.currentPhotoIndex)
        userDefaults.set(totalCount, forKey: Keys.totalPhotosCount)
        userDefaults.set(sortedCount, forKey: Keys.sortedPhotosCount)
        userDefaults.set(Date(), forKey: Keys.lastSortingSession)
    }
    
    func resetProgress() {
        currentPhotoIndex = 0
        totalPhotosCount = 0
        sortedPhotosCount = 0
        
        userDefaults.removeObject(forKey: Keys.currentPhotoIndex)
        userDefaults.removeObject(forKey: Keys.totalPhotosCount)
        userDefaults.removeObject(forKey: Keys.sortedPhotosCount)
        userDefaults.removeObject(forKey: Keys.lastSortingSession)
    }
    
    func updateCurrentIndex(_ index: Int) {
        currentPhotoIndex = index
        userDefaults.set(index, forKey: Keys.currentPhotoIndex)
    }
}

// MARK: - Models & Enums

enum SwipeDecision: CaseIterable {
    case like, dislike
    
    var emoji: String {
        switch self {
        case .like: "❤️"
        case .dislike: "❌"
        }
    }
    
    var title: String {
        switch self {
        case .like: "LIKE!"
        case .dislike: "NOPE!"
        }
    }
    
    var color: Color {
        switch self {
        case .like: .green
        case .dislike: .red
        }
    }
}

struct ActionHistory: Identifiable {
    let id = UUID()
    let photo: PhotoItem
    let decision: SwipeDecision
    let timestamp: Date
    let photoIndex: Int
    
    init(photo: PhotoItem, decision: SwipeDecision, photoIndex: Int) {
        self.photo = photo
        self.decision = decision
        self.photoIndex = photoIndex
        self.timestamp = Date()
    }
}

struct PhotoItem: Identifiable, Hashable {
    let id = UUID()
    let asset: PHAsset
    let image: UIImage
    let creationDate: Date?
    let location: CLLocation?
    let fileSize: Int64
    
    var formattedDate: String {
        guard let date = creationDate else { return "Неизвестная дата" }
        return DateFormatter.photoFormatter.string(from: date)
    }
    
    var formattedSize: String {
        "\(fileSize / 1024 / 1024) MB"
    }
    
    var locationString: String? {
        guard let location = location else { return nil }
        return String(format: "%.4f, %.4f", 
                     location.coordinate.latitude, 
                     location.coordinate.longitude)
    }
}

// MARK: - Photo Manager

@MainActor
final class PhotoManager: ObservableObject {
    @Published var photos: [PhotoItem] = []
    @Published var allAssets: [PHAsset] = [] // Все PHAsset объекты (легкие метаданные)
    @Published var isLoading = false
    @Published var deletedCount = 0
    @Published var keptCount = 0
    @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published var actionHistory: [ActionHistory] = []
    @Published var pendingDeleteAssets: [PHAsset] = []
    
    private let imageManager = PHImageManager.default()
    private let targetSize = CGSize(width: 1200, height: 1200) // Увеличено для лучшего качества
    private let thumbnailSize = CGSize(width: 200, height: 200) // Увеличено для лучшего качества в grid
    private let maxHistorySize = 10 // Максимум 10 последних действий
    private let batchDeleteSize = 20 // Удаляем по 20 фото за раз
    private let preloadCount = 5 // Предзагружаем 5 следующих фото
    
    // Кэш загруженных изображений
    private var imageCache: [String: UIImage] = [:]
    private var thumbnailCache: [String: UIImage] = [:]
    
    let progressManager = ProgressManager()
    
    init() {
        checkAuthorizationStatus()
    }
    
    func checkAuthorizationStatus() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }
    
    func requestPhotoAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorizationStatus = status
        return status == .authorized
    }
    
    func loadPhotos() async {
        guard authorizationStatus == .authorized else { return }
        
        isLoading = true
        defer { isLoading = false }
        
        do {
            let fetchOptions = PHFetchOptions()
            fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            // Загружаем только метаданные всех фотографий (очень быстро)
            fetchOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            fetchOptions.includeHiddenAssets = false
            
            // ИСПРАВЛЕНИЕ: Предварительно загружаем все необходимые метаданные
            // чтобы избежать синхронной загрузки на главном потоке
            fetchOptions.fetchLimit = 0 // Загружаем все
            fetchOptions.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
            
            // ПРИМЕЧАНИЕ: fetchPropertySets доступен только в iOS 16+
            // Для iOS 18.5 эти настройки должны помочь с производительностью
            fetchOptions.includeHiddenAssets = false
            fetchOptions.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared]
            
            let allPhotos = PHAsset.fetchAssets(with: fetchOptions)
            
            // Преобразуем PHFetchResult в массив
            var assets: [PHAsset] = []
            allPhotos.enumerateObjects { asset, index, _ in
                assets.append(asset)
            }
            
            allAssets = assets
            print("Загружены метаданные \(assets.count) фотографий (без изображений) - быстро!")
            
            // Обновляем общий счетчик
            progressManager.saveProgress(
                currentIndex: progressManager.currentPhotoIndex,
                totalCount: assets.count,
                sortedCount: progressManager.sortedPhotosCount
            )
            
            // Начинаем с текущей позиции
            let startIndex = max(0, progressManager.currentPhotoIndex)
            print("Начинаем сортировку с фотографии \(startIndex + 1) из \(assets.count)")
            
            // Предзагружаем первую пачку изображений для сортировки
            await setupPhotosForSorting(startFromIndex: startIndex)
            
            print("Готово! \(assets.count) фотографий доступны. Изображения загружаются по требованию.")
    }
    }
    
    func setupPhotosForSorting(startFromIndex: Int? = nil) async {
        let startIndex = startFromIndex ?? progressManager.currentPhotoIndex
        
        // Устанавливаем фотографии для сортировки начиная с нужного индекса
        if startIndex < allAssets.count {
            progressManager.updateCurrentIndex(startIndex)
            print("Начинаем сортировку с фотографии \(startIndex + 1) из \(allAssets.count)")
            
            // Загружаем только небольшое количество фото заранее (предзагрузка)
            await preloadPhotosFromIndex(startIndex)
        } else {
            photos = []
            print("Сортировка завершена! Все \(allAssets.count) фотографий обработаны.")
        }
    }
    
    private func preloadPhotosFromIndex(_ startIndex: Int) async {
        let endIndex = min(startIndex + preloadCount, allAssets.count)
        let assetsToLoad = Array(allAssets[startIndex..<endIndex])
        
        print("Предзагружаем \(assetsToLoad.count) фотографий начиная с индекса \(startIndex)")
        
        var loadedPhotos: [PhotoItem] = []
        
        for asset in assetsToLoad {
            if let photoItem = await loadPhotoItem(from: asset) {
                loadedPhotos.append(photoItem)
            }
        }
        
        photos = loadedPhotos
        print("Предзагружено \(photos.count) фотографий для сортировки")
    }
    
    // Загружаем следующую порцию фото когда текущие заканчиваются
    func loadMorePhotosIfNeeded(currentIndex: Int) async {
        // Если осталось меньше 3 фото, догружаем следующие
        if currentIndex >= photos.count - 3 {
            let nextStartIndex = progressManager.currentPhotoIndex + photos.count
            
            if nextStartIndex < allAssets.count {
                print("Догружаем следующие фотографии начиная с глобального индекса \(nextStartIndex)")
                await appendMorePhotos(startIndex: nextStartIndex)
            }
        }
    }
    
    // Добавляем новые фото к существующим вместо замены
    private func appendMorePhotos(startIndex: Int) async {
        let endIndex = min(startIndex + preloadCount, allAssets.count)
        let assetsToLoad = Array(allAssets[startIndex..<endIndex])
        
        print("Добавляем \(assetsToLoad.count) фотографий к существующим \(photos.count)")
        
        // Получаем список уже загруженных asset ID для избежания дубликатов
        let existingAssetIds = Set(photos.map { $0.asset.localIdentifier })
        
        var newPhotos: [PhotoItem] = []
        
        for asset in assetsToLoad {
            // Проверяем что этот asset еще не загружен
            if !existingAssetIds.contains(asset.localIdentifier) {
                if let photoItem = await loadPhotoItem(from: asset) {
                    newPhotos.append(photoItem)
                } else {
                    print("Не удалось загрузить asset \(asset.localIdentifier) - возможно недоступен")
                }
            } else {
                print("Пропускаем дубликат asset \(asset.localIdentifier)")
            }
        }
        
        // Добавляем к существующему массиву только новые фото
        if !newPhotos.isEmpty {
            photos.append(contentsOf: newPhotos)
            print("Добавлено \(newPhotos.count) новых фотографий. Теперь доступно \(photos.count) фотографий для сортировки")
        } else {
            print("Нет новых фотографий для добавления - все уже загружены или недоступны")
        }
    }
    
    private func loadPhotoItem(from asset: PHAsset) async -> PhotoItem? {
        // Предварительная проверка доступности asset
        guard asset.canPerform(.content) else {
            print("Asset \(asset.localIdentifier) недоступен для загрузки")
            return nil
        }
        
        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat // Максимальное качество
            options.isNetworkAccessAllowed = true // Разрешаем iCloud загрузку
            options.isSynchronous = false
            options.resizeMode = .exact // Точное соответствие размеру для лучшего качества
            options.allowSecondaryDegradedImage = true // ИСПРАВЛЕНИЕ: Принимаем деградированные версии как fallback
            
            // ИСПРАВЛЕНИЕ: Добавляем обработку ошибок изображений
            options.progressHandler = { progress, error, _, _ in
                if let error = error {
                    print("Ошибка загрузки asset \(asset.localIdentifier): \(error.localizedDescription)")
                }
            }
            
            var isCompleted = false
            var hasReceivedHighQuality = false
            
            // Увеличенный таймаут для качественной загрузки iCloud фото
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
                if !isCompleted {
                    isCompleted = true
                    print("Таймаут загрузки высокого качества для asset \(asset.localIdentifier)")
                    continuation.resume(returning: nil)
                }
            }
            
            imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                guard !isCompleted else { return } // Предотвращаем двойное выполнение
                
                // ИСПРАВЛЕНИЕ: Улучшенная обработка ошибок
                if let error = info?[PHImageErrorKey] as? Error {
                    print("Ошибка загрузки asset \(asset.localIdentifier): \(error.localizedDescription)")
                    // Не завершаем сразу, возможно придет деградированная версия
                    return
                }
                
                if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled {
                    print("Загрузка asset \(asset.localIdentifier) отменена")
                    if !hasReceivedHighQuality {
                        isCompleted = true
                        continuation.resume(returning: nil)
                    }
                    return
                }
                
                guard let image = image else {
                    print("Не удалось получить изображение для asset \(asset.localIdentifier)")
                    if !hasReceivedHighQuality {
                        isCompleted = true
                        continuation.resume(returning: nil)
                    }
                    return
                }
                
                // ИСПРАВЛЕНИЕ: Обрабатываем поврежденные изображения
                // Проверяем что изображение валидно
                if image.size.width <= 0 || image.size.height <= 0 {
                    print("Asset \(asset.localIdentifier) - поврежденное изображение (недопустимый размер)")
                    if !hasReceivedHighQuality {
                        isCompleted = true
                        continuation.resume(returning: nil)
                    }
                    return
                }
                
                // Проверяем качество изображения
                if let isDegraded = info?[PHImageResultIsDegradedKey] as? Bool, isDegraded {
                    print("Asset \(asset.localIdentifier) - получили деградированную версию, ждем высокое качество...")
                    // ИСПРАВЛЕНИЕ: Если это деградированная версия, но она единственная доступная - используем её
                    if let inCloudShared = info?[PHImageResultIsInCloudKey] as? Bool, inCloudShared {
                        print("Asset \(asset.localIdentifier) - используем деградированную версию (iCloud)")
                        hasReceivedHighQuality = true
                        isCompleted = true
                        
                        let photoItem = PhotoItem(
                            asset: asset,
                            image: image,
                            creationDate: asset.creationDate,
                            location: asset.location,
                            fileSize: self.getFileSize(for: asset)
                        )
                        
                        // Кэшируем для повторного использования
                        self.imageCache[asset.localIdentifier] = image
                        
                        // ИСПРАВЛЕНИЕ: Управляем размером кэша для предотвращения переполнения памяти
                        self.manageCacheSize()
                        
                        continuation.resume(returning: photoItem)
                        return
                    }
                    return // Продолжаем ждать высокое качество
                }
                
                // Это высококачественное изображение!
                print("Asset \(asset.localIdentifier) - получили ВЫСОКОЕ качество! ✨")
                hasReceivedHighQuality = true
                isCompleted = true
                
                let photoItem = PhotoItem(
                    asset: asset,
                    image: image,
                    creationDate: asset.creationDate,
                    location: asset.location,
                    fileSize: self.getFileSize(for: asset)
                )
                
                // Кэшируем для повторного использования
                self.imageCache[asset.localIdentifier] = image
                
                // ИСПРАВЛЕНИЕ: Управляем размером кэша для предотвращения переполнения памяти
                self.manageCacheSize()
                
                continuation.resume(returning: photoItem)
            }
        }
    }
    
    func deletePhoto(at index: Int, currentDisplayIndex: Int) async {
        guard index < photos.count else { return }
        
        let photoToDelete = photos[index]
        
        // Проверяем, что фото еще не добавлено в очередь удаления (избегаем дублирования)
        if !pendingDeleteAssets.contains(where: { $0.localIdentifier == photoToDelete.asset.localIdentifier }) {
            pendingDeleteAssets.append(photoToDelete.asset)
        }
        
        // Убираем из интерфейса сразу
        photos.remove(at: index)
        
        // ВАЖНО: Обновляем глобальный прогресс при удалении первого фото из буфера
        if index == 0 {
            let newGlobalIndex = progressManager.currentPhotoIndex + 1
            progressManager.updateCurrentIndex(newGlobalIndex)
            print("Обновлен глобальный прогресс: теперь на фото \(newGlobalIndex)")
        }
        
        // После удаления проверяем нужна ли догрузка новых фото
        await loadMorePhotosIfNeeded(currentIndex: currentDisplayIndex)
        
        // Если накопилось достаточно фото или это последнее фото, удаляем batch
        if pendingDeleteAssets.count >= batchDeleteSize || photos.isEmpty {
            await performBatchDelete()
        }
        // Таймер убран - удаление только вручную через кнопку
        
        print("Фотография подготовлена к удалению. Осталось в буфере: \(photos.count)")
    }
    
    private func performBatchDelete() async {
        guard !pendingDeleteAssets.isEmpty else { return }
        
        let assetsToDelete = pendingDeleteAssets
        pendingDeleteAssets.removeAll()
        
        // Дополнительная проверка: убираем assets, которые могли быть восстановлены
        let validAssetsToDelete = await filterValidAssetsForDeletion(assetsToDelete)
        
        guard !validAssetsToDelete.isEmpty else {
            print("Нет валидных фотографий для удаления (все восстановлены)")
            return
        }
        
        do {
            // Удаляем все накопленные фото одним запросом
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(validAssetsToDelete as NSArray)
            }
            
            print("Batch удаление \(validAssetsToDelete.count) фотографий завершено")
        } catch {
            print("Ошибка batch удаления: \(error)")
            // В случае ошибки возвращаем только валидные assets обратно для повторной попытки
            pendingDeleteAssets.append(contentsOf: validAssetsToDelete)
        }
    }
    
    // Фильтрует assets, исключая те, которые уже были удалены или недоступны
    private func filterValidAssetsForDeletion(_ assets: [PHAsset]) async -> [PHAsset] {
        return assets.filter { asset in
            // Проверяем, что asset еще существует и не поврежден
            let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [asset.localIdentifier], options: nil)
            if fetchResult.count == 0 {
                print("Asset \(asset.localIdentifier) больше не существует")
                return false
            }
            
            let fetchedAsset = fetchResult.firstObject!
            // Проверяем, что asset доступен для удаления
            return fetchedAsset.canPerform(.delete)
        }
    }
    
    // Принудительное удаление всех накопленных фото
    func flushPendingDeletes() async {
        // Сначала очищаем массив от восстановленных фотографий
        await cleanupRestoredAssets()
        // Затем удаляем оставшиеся
        await performBatchDelete()
    }
    
    // Очищаем массив от фотографий, которые были восстановлены из корзины
    func cleanupRestoredAssets() async {
        guard !pendingDeleteAssets.isEmpty else { return }
        
        let originalCount = pendingDeleteAssets.count
        
        // Фильтруем только те assets, которые действительно можно удалить
        // Восстановленные фотографии будут недоступны для удаления
        pendingDeleteAssets = pendingDeleteAssets.filter { asset in
            // Проверяем, что asset существует
            let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [asset.localIdentifier], options: nil)
            guard fetchResult.count > 0 else {
                print("Asset \(asset.localIdentifier) больше не существует")
                return false // Удаляем из очереди
            }
            
            let fetchedAsset = fetchResult.firstObject!
            
            // Если фотография была восстановлена, она может не быть доступной для удаления
            // или может иметь измененные свойства
            let canDelete = fetchedAsset.canPerform(.delete)
            
            if !canDelete {
                print("Asset \(asset.localIdentifier) восстановлен и недоступен для удаления")
            }
            
            return canDelete // Оставляем в очереди только те, что можно удалить
        }
        
        let removedCount = originalCount - pendingDeleteAssets.count
        if removedCount > 0 {
            print("Удалено \(removedCount) восстановленных/недоступных фотографий из очереди удаления")
            
            // Принудительно обновляем UI на главном потоке
            DispatchQueue.main.async { [weak self] in
                self?.objectWillChange.send()
            }
        }
    }
    

    
    func keepPhoto(photo: PhotoItem, at index: Int) {
        keptCount += 1
        addToHistory(photo: photo, decision: .like, photoIndex: index)
        
        // Обновляем глобальный прогресс при лайке первого фото
        if index == 0 {
            let newGlobalIndex = progressManager.currentPhotoIndex + 1
            progressManager.updateCurrentIndex(newGlobalIndex)
            print("Обновлен глобальный прогресс после лайка: теперь на фото \(newGlobalIndex)")
        }
    }
    
    func recordDeletion(photo: PhotoItem, at index: Int) {
        deletedCount += 1
        addToHistory(photo: photo, decision: .dislike, photoIndex: index)
    }
    
    private func addToHistory(photo: PhotoItem, decision: SwipeDecision, photoIndex: Int) {
        let action = ActionHistory(photo: photo, decision: decision, photoIndex: photoIndex)
        actionHistory.insert(action, at: 0)
        
        // Ограничиваем размер истории
        if actionHistory.count > maxHistorySize {
            actionHistory.removeLast()
        }
    }
    
    func undoLastAction() async -> Bool {
        guard let lastAction = actionHistory.first else { return false }
        
        switch lastAction.decision {
        case .like:
            // Отменяем лайк - просто уменьшаем счетчик
            keptCount = max(0, keptCount - 1)
            
        case .dislike:
            // Отменяем удаление - уменьшаем счетчик
            deletedCount = max(0, deletedCount - 1)
            
            // Вставляем фото обратно в интерфейс
            photos.insert(lastAction.photo, at: lastAction.photoIndex)
            
            // ВАЖНО: Убираем фото из очереди удаления при отмене действия
            pendingDeleteAssets.removeAll { asset in
                asset.localIdentifier == lastAction.photo.asset.localIdentifier
            }
            
            print("Фото удалено из очереди удаления при отмене действия")
        }
        
        // Удаляем действие из истории
        actionHistory.removeFirst()
        return true
    }
    
    var canUndo: Bool {
        !actionHistory.isEmpty
    }
    
    // ИСПРАВЛЕНИЕ: Добавляем управление памятью для кэшей
    func clearCaches() {
        imageCache.removeAll()
        thumbnailCache.removeAll()
        print("Очищены кэши изображений для освобождения памяти")
    }
    
    func clearImageCache() {
        imageCache.removeAll()
        print("Очищен кэш основных изображений")
    }
    
    func clearThumbnailCache() {
        thumbnailCache.removeAll()
        print("Очищен кэш thumbnails")
    }
    
    // Периодическая очистка кэша при достижении лимита
    private func manageCacheSize() {
        let maxCacheSize = 50 // Максимум 50 изображений в кэше
        
        if imageCache.count > maxCacheSize {
            let oldestKeys = Array(imageCache.keys.prefix(imageCache.count - maxCacheSize))
            for key in oldestKeys {
                imageCache.removeValue(forKey: key)
            }
            print("Очищено \(oldestKeys.count) старых изображений из кэша")
        }
        
        if thumbnailCache.count > maxCacheSize * 2 { // Больше thumbnails можно хранить
            let oldestKeys = Array(thumbnailCache.keys.prefix(thumbnailCache.count - maxCacheSize * 2))
            for key in oldestKeys {
                thumbnailCache.removeValue(forKey: key)
            }
            print("Очищено \(oldestKeys.count) старых thumbnails из кэша")
        }
    }
    
    private func getFileSize(for asset: PHAsset) -> Int64 {
        // Используем реальный размер из ресурсов PHAsset
        let resources = PHAssetResource.assetResources(for: asset)
        
        // Ищем основной ресурс изображения
        if let mainResource = resources.first(where: { $0.type == .photo || $0.type == .fullSizePhoto }) {
            // Получаем размер файла из ресурса
            if let fileSize = mainResource.value(forKey: "fileSize") as? Int64 {
                return fileSize
            }
        }
        
        // Fallback - приблизительный расчет если не удалось получить реальный размер
        let pixelCount = Int64(asset.pixelWidth * asset.pixelHeight)
        let estimatedSize = pixelCount * 3 // Более консервативная оценка (3 байта на пиксель)
        
        return estimatedSize
    }
}

// MARK: - Extensions

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

extension DateFormatter {
    static let shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }()
}

// MARK: - Main View

// MARK: - Main Content View

struct ContentView: View {
    @StateObject private var photoManager = PhotoManager()
    @State private var currentView: AppState = .menu
    
    enum AppState {
        case menu
        case sorting
    }
    
    var body: some View {
        NavigationStack {
            Group {
                switch currentView {
                case .menu:
                    MainMenuView(photoManager: photoManager) { startIndex in
                        startSorting(from: startIndex)
                    }
                    
                case .sorting:
                    PhotoSortingView(photoManager: photoManager) {
                        currentView = .menu
                    }
                }
            }
            .animation(.easeInOut(duration: 0.3), value: currentView)
        }
        .task {
            if await photoManager.requestPhotoAccess() {
                await photoManager.loadPhotos()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task {
                await photoManager.cleanupRestoredAssets()
            }
        }
    }
    
    private func startSorting(from index: Int?) {
        Task {
            if let index = index {
                // Начинаем с определенного индекса
                await photoManager.setupPhotosForSorting(startFromIndex: index)
            } else {
                // Продолжаем с текущей позиции или начинаем сначала
                await photoManager.setupPhotosForSorting()
            }
            currentView = .sorting
        }
    }
}

// MARK: - Photo Sorting View

struct PhotoSortingView: View {
    @ObservedObject var photoManager: PhotoManager
    let onBackToMenu: () -> Void
    
    @State private var currentPhotoIndex = 0 // Всегда показываем первое фото в буфере
    @State private var dragOffset = CGSize.zero
    @State private var rotationAngle: Double = 0
    @State private var showDecisionFeedback = false
    @State private var lastDecision: SwipeDecision?
    @State private var showFullScreen = false
    @State private var fullScreenStartIndex = 0
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                backgroundGradient
                
                VStack(spacing: 0) {
                    headerView
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                    
                    Spacer(minLength: 20)
                    
                    photoCardStack(geometry: geometry)
                        .padding(.horizontal, 20)
                    
                    Spacer(minLength: 20)
                    
                    actionButtons
                        .padding(.horizontal, 20)
                        .padding(.bottom, 10)
                    
                    statisticsView
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                }
                
                if showDecisionFeedback, let decision = lastDecision {
                    DecisionFeedbackView(decision: decision)
                        .transition(.asymmetric(
                            insertion: .scale.combined(with: .opacity),
                            removal: .opacity
                        ))
                }
            }
        }
        .navigationBarHidden(true)
        .fullScreenCover(isPresented: $showFullScreen) {
            FullScreenPhotoView(
                isPresented: $showFullScreen,
                photos: Array(photoManager.photos.dropFirst(currentPhotoIndex)),
                currentIndex: fullScreenStartIndex
            )
        }
        .onAppear {
            // Очищаем восстановленные фотографии при каждом открытии
            Task {
                await photoManager.cleanupRestoredAssets()
            }
        }
        .onDisappear {
            // Сохраняем прогресс при выходе из сортировки
            let currentGlobalIndex = photoManager.progressManager.currentPhotoIndex + currentPhotoIndex
            photoManager.progressManager.saveProgress(
                currentIndex: currentGlobalIndex,
                totalCount: photoManager.allAssets.count,
                sortedCount: photoManager.deletedCount + photoManager.keptCount
            )
            
            Task {
                await photoManager.flushPendingDeletes()
            }
        }
        .alert("Доступ к фотографиям", isPresented: .constant(photoManager.authorizationStatus == .denied)) {
            Button("Настройки") { openSettings() }
            Button("Отмена", role: .cancel) { }
        } message: {
            Text("Для работы приложения необходим доступ к фотографиям. Разрешите доступ в настройках.")
        }
    }
    
    // MARK: - View Components
    
    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                .orange.opacity(0.1),
                .pink.opacity(0.1),
                .red.opacity(0.1)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
    
    private var headerView: some View {
        VStack(spacing: 8) {
            HStack {
                // Кнопка "Назад"
                Button(action: onBackToMenu) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Меню")
                    }
                    .font(.subheadline.bold())
                    .foregroundStyle(.blue)
                }
                
                Spacer()
                
                // Прогресс сортировки
                VStack(spacing: 2) {
                    Text("Фото \(currentGlobalIndex + 1) из \(photoManager.allAssets.count)")
                        .font(.headline.bold())
                    
                    Text("\(String(format: "%.1f", currentProgress))% завершено")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                // Кнопка принудительного удаления с пульсирующим эффектом
                if !photoManager.pendingDeleteAssets.isEmpty {
                    Button(action: {
                        Task {
                            await photoManager.flushPendingDeletes()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "trash.fill")
                            Text("\(photoManager.pendingDeleteAssets.count)")
                        }
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.red, in: Capsule())
                    }
                    .scaleEffect(0.9)
                    .overlay(
                        Capsule()
                            .stroke(.red, lineWidth: 2)
                            .scaleEffect(1.2)
                            .opacity(0.6)
                            .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false), value: photoManager.pendingDeleteAssets.count)
                    )
                }
            }
            
            // Прогресс-бар
            ProgressView(value: currentProgress / 100.0)
                .tint(.blue)
            
            HStack {
                Text("\(remainingPhotosCount) фото осталось")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                if !photoManager.pendingDeleteAssets.isEmpty {
                    Text("• \(photoManager.pendingDeleteAssets.count) ждут удаления (нажмите красную кнопку)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                
                Spacer()
            }
        }
    }
    
    private var currentGlobalIndex: Int {
        photoManager.progressManager.currentPhotoIndex + currentPhotoIndex
    }
    
    private var currentProgress: Double {
        guard photoManager.allAssets.count > 0 else { return 0 }
        return Double(currentGlobalIndex) / Double(photoManager.allAssets.count) * 100
    }
    
    private var remainingPhotosCount: Int {
        // Показываем общее количество оставшихся фото (включая те что еще не загружены)
        let totalRemaining = photoManager.allAssets.count - currentGlobalIndex
        return max(0, totalRemaining)
    }
    
    private func photoCardStack(geometry: GeometryProxy) -> some View {
        ZStack {
            if photoManager.photos.isEmpty {
                emptyStateView
            } else {
                cardStackView(geometry: geometry)
            }
        }
        .frame(maxHeight: min(geometry.size.height * 0.6, max(300, geometry.size.height - 300)))
    }
    
    @ViewBuilder
    private var emptyStateView: some View {
        if photoManager.isLoading {
            ProgressView("Загрузка фотографий...")
                .scaleEffect(1.2)
                .tint(.orange)
        } else if photoManager.authorizationStatus != .authorized {
            VStack(spacing: 16) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 60))
                    .foregroundStyle(.orange)
                
                Text("Нет доступа к фотографиям")
                    .font(.title2.bold())
                
                Text("Разрешите доступ к фотографиям в настройках")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        } else {
            VStack(spacing: 16) {
                Text("🎉")
                    .font(.system(size: 60))
                
                Text("Все фотографии отсортированы!")
                    .font(.title2.bold())
                    .foregroundStyle(.green)
                    .multilineTextAlignment(.center)
            }
        }
    }
    
    private func cardStackView(geometry: GeometryProxy) -> some View {
        ForEach(0..<min(3, remainingPhotosCount), id: \.self) { cardIndex in
            let photoIndex = currentPhotoIndex + cardIndex
            
            if photoIndex < photoManager.photos.count {
                TinderPhotoCard(
                    photo: photoManager.photos[photoIndex],
                    isTopCard: cardIndex == 0,
                    dragOffset: cardIndex == 0 ? dragOffset : .zero,
                    rotationAngle: cardIndex == 0 ? rotationAngle : 0,
                    availableHeight: min(geometry.size.height * 0.65, max(400, geometry.size.height - 250))
                )
                .frame(
                    maxWidth: min(geometry.size.width - 32, 400),
                    maxHeight: min(geometry.size.height * 0.65, max(400, geometry.size.height - 250))
                )
                // Более выраженный стек эффект
                .scaleEffect(1.0 - CGFloat(cardIndex) * 0.04) // Увеличен эффект уменьшения
                .offset(
                    x: CGFloat(cardIndex) * -2, // Небольшое горизонтальное смещение для глубины
                    y: CGFloat(cardIndex) * 12   // Увеличено вертикальное смещение
                )
                .brightness(-Double(cardIndex) * 0.03) // Легкое затемнение нижних карточек
                .zIndex(Double(3 - cardIndex))
                .animation(
                    .spring(response: 0.6, dampingFraction: 0.8, blendDuration: 0.3), 
                    value: cardIndex
                )
                .animation(
                    .spring(response: 0.5, dampingFraction: 0.75, blendDuration: 0.2), 
                    value: currentPhotoIndex
                )
                .simultaneousGesture(longPressGesture)
                .gesture(cardIndex == 0 ? swipeGesture : nil)
            }
        }
    }
    
    private var swipeGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                // Более плавная анимация во время drag с улучшенной responsi
                withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.95, blendDuration: 0.1)) {
                    dragOffset = value.translation
                    // Более реалистичный поворот - как будто карточку держат за угол
                    rotationAngle = Double(value.translation.width / 10) // Уменьшено для более тонкого эффекта
                }
            }
            .onEnded { value in
                let swipeThreshold: CGFloat = 100 // Немного уменьшено для чувствительности
                let velocityThreshold: CGFloat = 400 // Уменьшено для более отзывчивого свайпа
                
                let swipeVelocity = sqrt(pow(value.velocity.width, 2) + pow(value.velocity.height, 2))
                
                if abs(value.translation.width) > swipeThreshold || swipeVelocity > velocityThreshold {
                    let decision: SwipeDecision = value.translation.width > 0 ? .like : .dislike
                    performSwipeAction(decision)
                } else {
                    // Мгновенно возвращаем карточку на место без анимации
                    dragOffset = .zero
                    rotationAngle = 0
                }
            }
    }
    
    private var longPressGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .onEnded { _ in
                openFullScreenView()
            }
    }
    
    private func openFullScreenView() {
        fullScreenStartIndex = 0
        showFullScreen = true
    }
    
    private var actionButtons: some View {
        HStack {
            Spacer()
            
            ActionButton(
                icon: "xmark",
                color: .red,
                action: { performSwipeAction(.dislike) }
            )
            
            Spacer()
            
            // Кнопка отмены
            ActionButton(
                icon: "arrow.uturn.backward",
                color: photoManager.canUndo ? .blue : .gray,
                action: { performUndoAction() }
            )
            .disabled(!photoManager.canUndo)
            .opacity(photoManager.canUndo ? 1.0 : 0.5)
            .overlay(
                // Показываем иконку последнего действия
                photoManager.canUndo && photoManager.actionHistory.first != nil ?
                Image(systemName: photoManager.actionHistory.first!.decision == .like ? "heart.fill" : "trash.fill")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(2)
                    .background(
                        Circle()
                            .fill(photoManager.actionHistory.first!.decision.color)
                    )
                    .offset(x: 15, y: -15)
                : nil
            )
            
            Spacer()
            
            ActionButton(
                icon: "heart.fill",
                color: .green,
                action: { performSwipeAction(.like) }
            )
            
            Spacer()
        }
    }
    
    private var statisticsView: some View {
        HStack(spacing: 24) {
            StatisticItem(
                icon: "xmark.circle.fill",
                count: photoManager.deletedCount,
                color: .red
            )
            
            Spacer()
            
            StatisticItem(
                icon: "heart.circle.fill",
                count: photoManager.keptCount,
                color: .green
            )
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.1), radius: 10, y: 5)
    }
    
    // MARK: - Actions
    
    private func performSwipeAction(_ decision: SwipeDecision) {
        guard currentPhotoIndex < photoManager.photos.count else { return }
        
        lastDecision = decision
        
        // Более реалистичная анимация улетания карточки (как в Tinder)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85, blendDuration: 0.15)) {
            showDecisionFeedback = true
            // Карточка улетает дальше и быстрее
            dragOffset = CGSize(
                width: decision == .like ? 1200 : -1200, // Увеличено расстояние
                height: decision == .like ? -200 : -150   // Более естественное движение вверх
            )
            // Более выраженный поворот при улетании  
            rotationAngle = decision == .like ? 35 : -35
        }
        
        Task {
            let currentPhoto = photoManager.photos[currentPhotoIndex]
            
            // Немного увеличенное время для более плавной анимации
            try? await Task.sleep(for: .milliseconds(450))
            
            // Обрабатываем действие после завершения анимации
            switch decision {
            case .like:
                photoManager.keepPhoto(photo: currentPhoto, at: currentPhotoIndex)
                // При лайке удаляем фото из буфера
                await MainActor.run {
                    photoManager.photos.removeFirst()
                    currentPhotoIndex = 0 // Сбрасываем на первое фото
                    
                    // Мгновенно сбрасываем позицию новой карточки
                    dragOffset = .zero
                    rotationAngle = 0
                }
                updateProgress()
                
            case .dislike:
                photoManager.recordDeletion(photo: currentPhoto, at: currentPhotoIndex)
                // Удаляем фото в корзину и убираем из списка
                await photoManager.deletePhoto(at: currentPhotoIndex, currentDisplayIndex: currentPhotoIndex)
                await MainActor.run {
                    currentPhotoIndex = 0 // Сбрасываем на первое фото
                    
                    // Мгновенно сбрасываем позицию новой карточки
                    dragOffset = .zero
                    rotationAngle = 0
                }
                updateProgress()
            }
            
            // Мгновенно скрываем feedback
            await MainActor.run {
                showDecisionFeedback = false
            }
        }
    }
    
    private func performUndoAction() {
        guard photoManager.canUndo, let lastAction = photoManager.actionHistory.first else { return }
        
        Task {
            let success = await photoManager.undoLastAction()
            if success {
                await MainActor.run {
                    // Мгновенно обновляем состояние без анимации
                    switch lastAction.decision {
                    case .like:
                        // При отмене лайка возвращаемся к предыдущему фото
                        if currentPhotoIndex > 0 {
                            currentPhotoIndex -= 1
                        }
                    case .dislike:
                        // При отмене дизлайка фото восстановлено в том же индексе, ничего не меняем
                        break
                    }
                    
                    // Мгновенно сбрасываем состояния без анимации
                    dragOffset = .zero
                    rotationAngle = 0
                    
                    // Мгновенно скрываем feedback
                    lastDecision = nil
                    showDecisionFeedback = false
                }
            }
        }
    }
    

    
    private func resetCardPosition() {
        // Мгновенно сбрасываем состояние карточки без анимации
        dragOffset = .zero
        rotationAngle = 0
    }
    
    private func updateProgress() {
        // Теперь currentPhotoIndex всегда 0, используем только глобальный прогресс
        photoManager.progressManager.saveProgress(
            currentIndex: photoManager.progressManager.currentPhotoIndex,
            totalCount: photoManager.allAssets.count,
            sortedCount: photoManager.deletedCount + photoManager.keptCount
        )
        
        // Догружаем следующие фото если необходимо (всегда передаем 0)
        Task {
            await photoManager.loadMorePhotosIfNeeded(currentIndex: 0)
        }
    }
    
    private func openSettings() {
        guard let settingsUrl = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(settingsUrl)
    }
}

// MARK: - Photo Grid Browser

struct PhotoGridBrowser: View {
    @Binding var isPresented: Bool
    @ObservedObject var photoManager: PhotoManager
    let onPhotoSelected: (Int) -> Void
    
    @State private var thumbnails: [String: UIImage] = [:]
    
    private let columns = Array(repeating: GridItem(.flexible(minimum: 100, maximum: 130), spacing: 4), count: 3)
    
    var body: some View {
        NavigationStack {
            ScrollView {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(Array(photoManager.allAssets.enumerated()), id: \.element.localIdentifier) { index, asset in
                            Button(action: {
                                onPhotoSelected(index)
                                isPresented = false
                            }) {
                                photoGridItem(asset: asset, index: index)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        .navigationTitle("Выберите фото (\(photoManager.allAssets.count))")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Отмена") {
                    isPresented = false
                }
            }
        }
        .task {
            await loadThumbnails()
        }
    }
    
    @ViewBuilder
    private func photoGridItem(asset: PHAsset, index: Int) -> some View {
        ZStack {
            // Базовый адаптивный контейнер
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.2))
                .aspectRatio(1, contentMode: .fit)
            
            // Изображение или placeholder
            Group {
                if let thumbnail = thumbnails[asset.localIdentifier] {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(.gray.opacity(0.3))
                        .overlay(
                            ProgressView()
                                .scaleEffect(0.8)
                        )
                        .onAppear {
                            // Ленивая загрузка thumbnail только когда элемент становится видимым
                            loadThumbnailForAsset(asset)
                        }
                }
            }
            .cornerRadius(8)
            
            // Градиент для читаемости номера
            LinearGradient(
                colors: [.clear, .black.opacity(0.6)],
                startPoint: .center,
                endPoint: .bottom
            )
            .cornerRadius(8)
            
            // Текстовая информация
            VStack {
                Spacer()
                HStack {
                    Text("\(index + 1)")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                    Spacer()
                    if let date = asset.creationDate {
                        Text(DateFormatter.shortDate.string(from: date))
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
            }
        }
        .aspectRatio(1, contentMode: .fit) // Адаптивный квадратный размер
    }
    
    private func loadThumbnails() async {
        // Больше не загружаем все thumbnails сразу - используем ленивую загрузку
        print("Готов к ленивой загрузке \(photoManager.allAssets.count) thumbnails по требованию")
    }
    
    // Загружаем thumbnail для конкретного asset по требованию
    private func loadThumbnailForAsset(_ asset: PHAsset) {
        // Проверяем что thumbnail еще не загружен и не загружается
        guard thumbnails[asset.localIdentifier] == nil else { return }
        
        Task {
            if let thumbnail = await photoManager.loadThumbnail(for: asset) {
                await MainActor.run {
                    thumbnails[asset.localIdentifier] = thumbnail
                }
            }
        }
    }
}

// MARK: - Thumbnail Loading Extension
extension PhotoManager {
    func loadThumbnail(for asset: PHAsset) async -> UIImage? {
        // Проверяем кэш
        if let cached = thumbnailCache[asset.localIdentifier] {
            return cached
        }
        
        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic // Лучшее качество для thumbnails
            options.resizeMode = .exact // Точное соответствие размеру
            options.isNetworkAccessAllowed = true // ИСПРАВЛЕНИЕ: Разрешаем iCloud для thumbnails (кратковременно)
            options.isSynchronous = false
            options.allowSecondaryDegradedImage = true // ИСПРАВЛЕНИЕ: Принимаем деградированные версии
            
            // ИСПРАВЛЕНИЕ: Добавляем обработку ошибок для thumbnails
            options.progressHandler = { progress, error, _, _ in
                if let error = error {
                    print("Ошибка загрузки thumbnail \(asset.localIdentifier): \(error.localizedDescription)")
                }
            }
            
            var isCompleted = false
            
            // Таймаут для thumbnails (короткий, так как они менее критичны)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                if !isCompleted {
                    isCompleted = true
                    continuation.resume(returning: nil)
                }
            }
            
            imageManager.requestImage(
                for: asset,
                targetSize: thumbnailSize,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                guard !isCompleted else { return } // Защита от двойного вызова
                isCompleted = true
                
                // ИСПРАВЛЕНИЕ: Улучшенная обработка ошибок для thumbnails
                if let error = info?[PHImageErrorKey] as? Error {
                    print("Ошибка загрузки thumbnail \(asset.localIdentifier): \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                    return
                }
                
                if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled {
                    continuation.resume(returning: nil)
                    return
                }
                
                if let image = image {
                    // ИСПРАВЛЕНИЕ: Проверяем валидность thumbnail
                    if image.size.width > 0 && image.size.height > 0 {
                        // Кэшируем thumbnail только если он валиден
                        self.thumbnailCache[asset.localIdentifier] = image
                        
                        // ИСПРАВЛЕНИЕ: Управляем размером кэша thumbnails
                        self.manageCacheSize()
                        
                        continuation.resume(returning: image)
                    } else {
                        print("Thumbnail \(asset.localIdentifier) - поврежденное изображение (недопустимый размер)")
                        continuation.resume(returning: nil)
                    }
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

// MARK: - Main Menu View

struct MainMenuView: View {
    @ObservedObject var photoManager: PhotoManager
    @State private var showGridBrowser = false
    let onStartSorting: (Int?) -> Void
    
    var body: some View {
        VStack(spacing: 24) {
            headerSection
            
            if photoManager.progressManager.hasProgress {
                progressSection
            }
            
            actionButtons
            
            statisticsSection
            
            Spacer()
        }
        .padding(.horizontal, 20)
        .background(backgroundGradient)
        .sheet(isPresented: $showGridBrowser) {
            PhotoGridBrowser(
                isPresented: $showGridBrowser,
                photoManager: photoManager,
                onPhotoSelected: { index in
                    onStartSorting(index)
                }
            )
        }
    }
    
    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                .orange.opacity(0.1),
                .pink.opacity(0.1),
                .red.opacity(0.1)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
    
    private var headerSection: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.stack.fill")
                .font(.system(size: 60))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.orange, .pink, .red],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            
            Text("Photo Swipe")
                .font(.largeTitle.bold())
                .foregroundStyle(
                    LinearGradient(
                        colors: [.orange, .pink, .red],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            
            Text("Быстрая сортировка фотографий свайпами")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 40)
    }
    
    @ViewBuilder
    private var progressSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Прогресс сортировки")
                    .font(.headline)
                Spacer()
                Text("\(String(format: "%.1f", photoManager.progressManager.progressPercentage))%")
                    .font(.headline.bold())
                    .foregroundStyle(.blue)
            }
            
            ProgressView(value: photoManager.progressManager.progressPercentage / 100.0)
                .tint(.blue)
            
            HStack {
                Text("Отсортировано: \(photoManager.progressManager.currentPhotoIndex)")
                Spacer()
                Text("Осталось: \(photoManager.progressManager.remainingCount)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
    
    private var actionButtons: some View {
        VStack(spacing: 16) {
            if photoManager.progressManager.hasProgress {
                Button(action: {
                    onStartSorting(nil) // Продолжить с текущей позиции
                }) {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("Продолжить сортировку")
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(.blue, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            
            Button(action: {
                showGridBrowser = true
            }) {
                HStack {
                    Image(systemName: "grid")
                    Text("Выбрать стартовую фотографию")
                }
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(.orange, in: RoundedRectangle(cornerRadius: 12))
            }
            
            Button(action: {
                onStartSorting(0) // Начать сначала
            }) {
                HStack {
                    Image(systemName: "arrow.counterclockwise")
                    Text("Начать сначала")
                }
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(.green, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
    
    private var statisticsSection: some View {
        VStack(spacing: 12) {
            Text("Статистика")
                .font(.headline)
            
            HStack(spacing: 24) {
                StatisticItem(
                    icon: "photo.fill",
                    count: photoManager.allAssets.count,
                    color: .blue,
                    title: "Всего фото"
                )
                
                StatisticItem(
                    icon: "xmark.circle.fill",
                    count: photoManager.deletedCount,
                    color: .red,
                    title: "Удалено"
                )
                
                StatisticItem(
                    icon: "heart.circle.fill",
                    count: photoManager.keptCount,
                    color: .green,
                    title: "Сохранено"
                )
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Supporting Views

struct TinderPhotoCard: View {
    let photo: PhotoItem
    let isTopCard: Bool
    let dragOffset: CGSize
    let rotationAngle: Double
    let availableHeight: CGFloat
    
    private var swipeStrength: Double {
        // Более плавная прогрессия силы свайпа
        min(1.0, Double(abs(dragOffset.width) / 100))
    }
    
    private var cardOpacity: Double {
        if !isTopCard { return 1.0 }
        // Более плавное изменение прозрачности
        let progress = abs(dragOffset.width) / UIScreen.main.bounds.width
        return max(0.3, 1.0 - progress * 0.7) // От 100% до 30% прозрачности
    }
    
    private var cornerOffset: CGSize {
        if !isTopCard { return .zero }
        let progress = abs(dragOffset.width) / UIScreen.main.bounds.width
        let cornerMultiplier = min(progress * 1.5, 1.0) // Немного более выраженное движение
        
        return CGSize(
            width: dragOffset.width * (1 + cornerMultiplier * 0.4), // Увеличено для более реалистичного движения
            height: dragOffset.width > 0 ? 
                -abs(dragOffset.width) * 0.25 : // Более выраженное движение к верхнему углу при лайке
                abs(dragOffset.width) * 0.35     // Более выраженное движение к нижнему углу при дизлайке
        )
    }
    
    // Новый эффект: карточки под текущей немного реагируют на движение верхней
    private var stackCardOffset: CGSize {
        if isTopCard { return .zero }
        let influence = abs(dragOffset.width) / UIScreen.main.bounds.width
        return CGSize(
            width: dragOffset.width * influence * 0.1, // Тонкое влияние на нижние карточки
            height: 0
        )
    }
    
    // Улучшенный масштаб для стек эффекта
    private var stackCardScale: Double {
        if isTopCard { 
            return 1.0 - swipeStrength * 0.02 // Немного уменьшаем при свайпе
        } else {
            let influence = abs(dragOffset.width) / UIScreen.main.bounds.width
            return 1.0 + influence * 0.02 // Нижние карточки немного увеличиваются при движении верхней
        }
    }
    
    var body: some View {
        ZStack {
            cardBackground
            
            VStack(spacing: 0) {
                photoImageView
            }
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }
        .aspectRatio(3/4, contentMode: .fit)
        .scaleEffect(stackCardScale)
        .rotationEffect(.degrees(rotationAngle))
        .opacity(cardOpacity)
        .offset(isTopCard ? cornerOffset : stackCardOffset)
        .animation(
            dragOffset == .zero ? 
                nil : // Без анимации при возврате
                .interactiveSpring(response: 0.25, dampingFraction: 0.95), // Интерактивное движение
            value: dragOffset
        )
    }
    
    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 20)
            .fill(.white)
            .shadow(
                color: .black.opacity(isTopCard ? 0.2 : 0.08),
                radius: isTopCard ? 25 : 10,
                y: isTopCard ? 10 : 5
            )
    }
    
    private var photoImageView: some View {
        GeometryReader { geometry in
            ZStack {
                Image(uiImage: photo.image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(
                        width: geometry.size.width,
                        height: min(availableHeight - 40, 500)
                    )
                    .clipped()
                
                bottomGradient
                photoMetadata
                
                if isTopCard && abs(dragOffset.width) > 40 {
                    swipeIndicatorOverlay
                }
            }
        }
        .frame(
            maxWidth: UIScreen.main.bounds.width - 32,
            maxHeight: min(availableHeight - 40, 500)
        )
    }
    
    private var bottomGradient: some View {
        LinearGradient(
            colors: [.clear, .black.opacity(0.7)],
            startPoint: .center,
            endPoint: .bottom
        )
        .frame(height: 120)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }
    
    private var photoMetadata: some View {
        VStack(alignment: .leading, spacing: 8) {
            Spacer()
            
            VStack(alignment: .leading, spacing: 6) {
                Text(photo.formattedDate)
                    .font(.headline.bold())
                    .foregroundStyle(.white)
                
                HStack {
                    if let locationString = photo.locationString {
                        Label(locationString, systemImage: "location.fill")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                    }
                    
                    Spacer()
                    
                    Text(photo.formattedSize)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.3), in: Capsule())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
    
    private var swipeIndicatorOverlay: some View {
        ZStack {
            if dragOffset.width < 0 {
                // Дизлайк - крестик в левом верхнем углу
                VStack {
                    HStack {
                        SwipeIcon(icon: "xmark", color: .red)
                            .padding(.leading, 20)
                            .padding(.top, 40)
                        Spacer()
                    }
                    Spacer()
                }
            } else {
                // Лайк - сердечко в правом верхнем углу  
                VStack {
                    HStack {
                        Spacer()
                        SwipeIcon(icon: "heart.fill", color: .green)
                            .padding(.trailing, 20)
                            .padding(.top, 40)
                    }
                    Spacer()
                }
            }
        }
        .opacity(swipeStrength * 0.8) // Полупрозрачные иконки
    }
}

struct SwipeIcon: View {
    let icon: String
    let color: Color
    
    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 50, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 80, height: 80)
            .background(
                Circle()
                    .fill(.white.opacity(0.2)) // Немного увеличена прозрачность фона
                    .overlay(
                        Circle()
                            .stroke(color, lineWidth: 4) // Увеличена толщина границы
                    )
                    .overlay(
                        // Добавляем пульсирующий эффект
                        Circle()
                            .stroke(color.opacity(0.4), lineWidth: 2)
                            .scaleEffect(1.3)
                            .animation(
                                .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                                value: UUID() // Постоянная анимация
                            )
                    )
            )
            .scaleEffect(0.95) // Немного увеличен базовый размер
            .rotationEffect(.degrees(color == .green ? -12 : 12)) // Увеличен угол поворота
            // Добавляем пружинящую анимацию появления
            .animation(.spring(response: 0.4, dampingFraction: 0.6, blendDuration: 0.2), value: icon)
            .shadow(color: color.opacity(0.3), radius: 8, y: 4) // Добавлена тень для глубины
    }
}

struct ActionButton: View {
    let icon: String
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title2.bold())
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(
                    Circle()
                        .fill(color)
                        .shadow(color: color.opacity(0.4), radius: 12, y: 6)
                )
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

struct StatisticItem: View {
    let icon: String
    let count: Int
    let color: Color
    let title: String?
    
    init(icon: String, count: Int, color: Color, title: String? = nil) {
        self.icon = icon
        self.count = count
        self.color = color
        self.title = title
    }
    
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            
            Text("\(count)")
                .font(.headline.bold())
            
            if let title = title {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct DecisionFeedbackView: View {
    let decision: SwipeDecision
    
    private var feedbackIcon: String {
        decision == .like ? "heart.fill" : "xmark"
    }
    
    var body: some View {
        VStack {
            Spacer()
            
            HStack {
                if decision == .dislike { Spacer() }
                
                VStack {
                    Image(systemName: feedbackIcon)
                        .font(.system(size: 60, weight: .bold))
                        .foregroundStyle(decision.color)
                        .frame(width: 120, height: 120)
                        .background(
                            Circle()
                                .fill(.white)
                                .overlay(
                                    Circle()
                                        .stroke(decision.color, lineWidth: 6)
                                )
                                .shadow(color: decision.color.opacity(0.3), radius: 20, y: 10)
                        )
                        .rotationEffect(.degrees(decision == .like ? -12 : 12))
                    
                    Text(decision.title)
                        .font(.title2.bold())
                        .foregroundStyle(decision.color)
                        .padding(.top, 8)
                }
                
                if decision == .like { Spacer() }
            }
            
            Spacer()
        }
    }
}

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.85 : 1.0) // Более выраженное нажатие
            .brightness(configuration.isPressed ? -0.1 : 0) // Легкое затемнение при нажатии
            .animation(
                .spring(response: 0.3, dampingFraction: 0.6, blendDuration: 0.1), 
                value: configuration.isPressed
            )
    }
}

struct FullScreenPhotoView: View {
    @Binding var isPresented: Bool
    let photos: [PhotoItem]
    @State var currentIndex: Int
    
    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            
            VStack {
                // Заголовок с кнопкой закрытия
                HStack {
                    Button("Готово") {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            isPresented = false
                        }
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding()
                    
                    Spacer()
                    
                    Text("\(currentIndex + 1) из \(photos.count)")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding()
                }
                
                // Основное фото с жестами
                TabView(selection: $currentIndex) {
                    ForEach(Array(photos.enumerated()), id: \.offset) { index, photo in
                        ZStack {
                            Image(uiImage: photo.image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .tag(index)
                        }
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut, value: currentIndex)
                
                // Информация о фото
                VStack(alignment: .leading, spacing: 8) {
                    if currentIndex < photos.count {
                        let photo = photos[currentIndex]
                        
                        Text(photo.formattedDate)
                            .font(.headline)
                            .foregroundStyle(.white)
                        
                        HStack {
                            if let locationString = photo.locationString {
                                Label(locationString, systemImage: "location.fill")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                            
                            Spacer()
                            
                            Text(photo.formattedSize)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                }
                .padding()
                .background(.ultraThinMaterial.opacity(0.3))
                .cornerRadius(12)
                .padding()
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
    }
}

// MARK: - Extensions

extension DateFormatter {
    static let photoFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "ru_RU")
        return formatter
    }()
}

// Preview будет в отдельном файле
