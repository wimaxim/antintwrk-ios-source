//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import Kingfisher
import SwiftUI
import Testing

@MainActor
struct MediaProviderTests {
    private var mediaLoader: MediaLoaderMock
    private var imageCache: MockImageCache
    private var reachabilitySubject = CurrentValueSubject<HomeserverReachability, Never>(.reachable)
    
    var mediaProvider: MediaProvider!
    
    init() {
        mediaLoader = MediaLoaderMock()
        imageCache = MockImageCache(name: "Test")
        
        mediaProvider = MediaProvider(mediaLoader: mediaLoader,
                                      imageCache: imageCache,
                                      homeserverReachabilityPublisher: reachabilitySubject.asCurrentValuePublisher())
    }
    
    @Test
    func loadingRetriedOnReconnection() async throws {
        let testImage = try loadTestImage()
        let pngData = try #require(testImage.pngData(), "Test image should contain valid .png data")
        
        let loadTask = try mediaProvider.loadImageRetryingOnReconnection(MediaSourceProxy(url: .mockMXCImage, mimeType: "image/jpeg"))
        
        reachabilitySubject.send(.unreachable)
        
        mediaLoader.loadMediaContentForSourceClosure = { [reachabilitySubject] _ in
            switch reachabilitySubject.value {
            case .unreachable, .suspended:
                reachabilitySubject.send(.reachable)
                throw MediaProviderTestsError.error
            case .reachable:
                return pngData
            }
        }
        
        let result = try? await loadTask.value
        
        #expect(result != nil)
        #expect(mediaLoader.loadMediaContentForSourceCallsCount == 2)
    }
    
    @Test
    func loadingRetriedOnReconnectionCancelsAfterSecondFailure() async throws {
        let loadTask = try mediaProvider.loadImageRetryingOnReconnection(MediaSourceProxy(url: .mockMXCImage, mimeType: "image/jpeg"))
        
        reachabilitySubject.send(.reachable)
        
        mediaLoader.loadMediaContentForSourceThrowableError = MediaProviderTestsError.error
        
        let result = try? await loadTask.value
        
        #expect(result == nil)
    }
    
    @Test
    func whenImageFromSourceWithSourceNil_nilReturned() {
        let image = mediaProvider.imageFromSource(nil, size: Avatars.Size.room(on: .timeline).scaledSize)
        #expect(image == nil)
    }
    
    @Test
    func whenImageFromSourceWithSourceNotNilAndImageCacheContainsImage_ImageIsReturned() throws {
        let avatarSize = Avatars.Size.room(on: .timeline)
        let url = URL.mockMXCImage
        let key = "\(url.absoluteString){\(avatarSize.scaledValue),\(avatarSize.scaledValue)}"
        let imageForKey = UIImage()
        imageCache.retrievedImagesInMemory[key] = imageForKey
        let image = try mediaProvider.imageFromSource(MediaSourceProxy(url: url, mimeType: "image/jpeg"),
                                                      size: avatarSize.scaledSize)
        #expect(image == imageForKey)
    }
    
    @Test
    func whenImageFromSourceWithSourceNotNilAndImageNotCached_nilReturned() throws {
        let image = try mediaProvider.imageFromSource(MediaSourceProxy(url: .mockMXCImage, mimeType: "image/jpeg"),
                                                      size: Avatars.Size.room(on: .timeline).scaledSize)
        #expect(image == nil)
    }
    
    @Test
    func whenLoadImageFromSourceAndImageCacheContainsImage_successIsReturned() async throws {
        let avatarSize = Avatars.Size.room(on: .timeline)
        let url = URL.mockMXCImage
        let key = "\(url.absoluteString){\(avatarSize.scaledValue),\(avatarSize.scaledValue)}"
        let imageForKey = UIImage()
        imageCache.retrievedImagesInMemory[key] = imageForKey
        let result = try await mediaProvider.loadImageFromSource(MediaSourceProxy(url: url, mimeType: "image/jpeg"),
                                                                 size: avatarSize.scaledSize)
        #expect(Result.success(imageForKey) == result)
    }
    
    @Test
    func whenLoadImageFromSourceAndImageNotCachedAndRetrieveImageSucceeds_successIsReturned() async throws {
        let avatarSize = Avatars.Size.room(on: .timeline)
        let url = URL.mockMXCImage
        let key = "\(url.absoluteString){\(avatarSize.scaledValue),\(avatarSize.scaledValue)}"
        let imageForKey = UIImage()
        imageCache.retrievedImages[key] = imageForKey
        let result = try await mediaProvider.loadImageFromSource(MediaSourceProxy(url: url, mimeType: "image/jpeg"),
                                                                 size: avatarSize.scaledSize)
        #expect(Result.success(imageForKey) == result)
    }
    
    @Test
    func whenLoadImageFromSourceAndImageNotCachedAndRetrieveImageFails_imageThumbnailIsLoaded() async throws {
        let avatarSize = Avatars.Size.room(on: .timeline)
        let expectedImage = try loadTestImage()
        
        mediaLoader.loadMediaThumbnailForSourceWidthHeightReturnValue = expectedImage.pngData()
        
        let result = try await mediaProvider.loadImageFromSource(MediaSourceProxy(url: .mockMXCImage, mimeType: "image/jpeg"),
                                                                 size: avatarSize.scaledSize)
        switch result {
        case .success(let image):
            #expect(image.pngData() == expectedImage.pngData())
        case .failure:
            Issue.record("Should be success")
        }
    }
    
    @Test
    func whenLoadImageFromSourceAndImageNotCachedAndRetrieveImageFails_imageIsStored() async throws {
        let avatarSize = Avatars.Size.room(on: .timeline)
        let url = URL.mockMXCImage
        let key = "\(url.absoluteString){\(avatarSize.scaledValue),\(avatarSize.scaledValue)}"
        let expectedImage = try loadTestImage()
        
        mediaLoader.loadMediaThumbnailForSourceWidthHeightReturnValue = expectedImage.pngData()
        
        _ = try await mediaProvider.loadImageFromSource(MediaSourceProxy(url: url, mimeType: "image/jpeg"),
                                                        size: avatarSize.scaledSize)
        let storedImage = try #require(imageCache.storedImages[key])
        #expect(expectedImage.pngData() == storedImage.pngData())
    }
    
    @Test
    func whenLoadImageFromSourceAndImageNotCachedAndRetrieveImageFailsAndNoAvatarSize_imageContentIsLoaded() async throws {
        let expectedImage = try loadTestImage()
        
        mediaLoader.loadMediaContentForSourceReturnValue = expectedImage.pngData()
        
        let result = try await mediaProvider.loadImageFromSource(MediaSourceProxy(url: .mockMXCImage, mimeType: "image/jpeg"),
                                                                 size: nil)
        switch result {
        case .success(let image):
            #expect(image.pngData() == expectedImage.pngData())
        case .failure:
            Issue.record("Should be success")
        }
    }
    
    @Test
    func whenLoadImageFromSourceAndImageNotCachedAndRetrieveImageFailsAndLoadImageThumbnailFails_errorIsThrown() async throws {
        mediaLoader.loadMediaThumbnailForSourceWidthHeightThrowableError = MediaProviderTestsError.error
        
        let result = try await mediaProvider.loadImageFromSource(MediaSourceProxy(url: .mockMXCImage, mimeType: "image/jpeg"),
                                                                 size: Avatars.Size.room(on: .timeline).scaledSize)
        switch result {
        case .success:
            Issue.record("Should fail")
        case .failure(let error):
            #expect(error == MediaProviderError.failedRetrievingImage)
        }
    }
    
    @Test
    func whenLoadImageFromSourceAndImageNotCachedAndRetrieveImageFailsAndNoAvatarSizeAndLoadImageContentFails_errorIsThrown() async throws {
        mediaLoader.loadMediaContentForSourceThrowableError = MediaProviderTestsError.error
        
        let result = try await mediaProvider.loadImageFromSource(MediaSourceProxy(url: .mockMXCImage, mimeType: "image/jpeg"),
                                                                 size: nil)
        switch result {
        case .success:
            Issue.record("Should fail")
        case .failure(let error):
            #expect(error == MediaProviderError.failedRetrievingImage)
        }
    }
    
    @Test
    func whenLoadImageFromSourceAndImageNotCachedAndRetrieveImageFailsAndImageThumbnailIsLoadedWithCorruptedData_errorIsThrown() async throws {
        mediaLoader.loadMediaThumbnailForSourceWidthHeightReturnValue = Data()
        
        let result = try await mediaProvider.loadImageFromSource(MediaSourceProxy(url: .mockMXCImage, mimeType: "image/jpeg"),
                                                                 size: Avatars.Size.room(on: .timeline).scaledSize)
        switch result {
        case .success:
            Issue.record("Should fail")
        case .failure(let error):
            #expect(error == MediaProviderError.invalidImageData)
        }
    }
    
    @Test
    func imageAndComposerTeardownInsideTaskLocalScope() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let image = try #require(UIImage(systemName: "person.crop.circle"))
        let provider = MediaProviderMock(.init())
        provider.imageFromSourceSizeClosure = { _, _ in image }
        provider.loadImageRetryingOnReconnectionSizeClosure = { _, _ in Task { image } }
        let composer = ComposerToolbarViewModel.mock()
        for _ in 0..<3 {
            try await ImageViewTeardownScope.$marker.withValue("image-teardown") {
                var signposter: Signposter? = Signposter()
                weak var releasedSignposter = signposter
                signposter = nil
                #expect(releasedSignposter == nil)
                var controller: UIHostingController<AnyView>? = UIHostingController(rootView: AnyView(VStack {
                    LoadableImage(url: .mockMXCAvatar, mediaType: .avatar, mediaProvider: provider) { Color.clear }.frame(width: 64, height: 64)
                    ComposerToolbar(context: composer.context)
                }))
                weak var releasedController = controller
                var window: UIWindow? = UIWindow(windowScene: scene)
                window?.rootViewController = controller
                window?.makeKeyAndVisible()
                controller?.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                window?.isHidden = true
                window?.rootViewController = nil
                window = nil
                controller = nil
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while releasedController != nil, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(50))
                }
                #expect(releasedController == nil)
            }
        }
    }
    
    private func loadTestImage() throws -> UIImage {
        guard let path = Bundle(for: UnitTestsAppCoordinator.self).path(forResource: "test_image", ofType: "png"),
              let image = UIImage(contentsOfFile: path) else {
            throw MediaProviderTestsError.error
        }
        return image
    }
}

private enum MediaProviderTestsError: Error {
    case error
}

private enum ImageViewTeardownScope {
    @TaskLocal static var marker: String?
}
