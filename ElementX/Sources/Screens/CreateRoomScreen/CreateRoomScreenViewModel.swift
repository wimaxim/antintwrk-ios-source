//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import MatrixRustSDK
import SwiftUI

typealias CreateRoomScreenViewModelType = StateStoreViewModel<CreateRoomScreenViewState, CreateRoomScreenViewAction>

class CreateRoomScreenViewModel: CreateRoomScreenViewModelType, CreateRoomScreenViewModelProtocol {
    private let userSession: UserSessionProtocol
    private let mediaUploadingPreprocessor: MediaUploadingPreprocessor
    private let analytics: AnalyticsServiceProtocol
    private let userIndicatorController: UserIndicatorControllerProtocol
    
    private let userDiscoveryService: UserDiscoveryServiceProtocol
    @CancellableTask private var groupSearchTask: Task<Void, Never>?
    private var syncNameAndAlias = true
    @CancellableTask private var checkAliasAvailabilityTask: Task<Void, Never>?
    
    private var actionsSubject: PassthroughSubject<CreateRoomScreenViewModelAction, Never> = .init()
    
    var actions: AnyPublisher<CreateRoomScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(isSpace: Bool,
         spaceSelectionMode: CreateRoomScreenSpaceSelectionMode,
         shouldShowCancelButton: Bool,
         userSession: UserSessionProtocol,
         analytics: AnalyticsServiceProtocol,
         userIndicatorController: UserIndicatorControllerProtocol,
         appSettings: AppSettings, userDiscoveryService: UserDiscoveryServiceProtocol? = nil) {
        self.userSession = userSession
        self.userDiscoveryService = userDiscoveryService ?? UserDiscoveryService(clientProxy: userSession.clientProxy)
        mediaUploadingPreprocessor = MediaUploadingPreprocessor(appSettings: appSettings)
        self.analytics = analytics
        self.userIndicatorController = userIndicatorController
        
        var selectedSpace: SpaceServiceRoom?
        let canSelectSpace: Bool
        var selectedAccessType = CreateRoomScreenAccessType.private
        switch spaceSelectionMode {
        case .editableSpacesList(let preSelectedSpace):
            canSelectSpace = true
            if let preSelectedSpace {
                selectedSpace = preSelectedSpace
                if preSelectedSpace.joinRule != .public {
                    selectedAccessType = .spaceMembers
                }
            }
        case .none:
            canSelectSpace = false
        }
        
        let bindings = CreateRoomScreenViewStateBindings(roomTopic: "",
                                                         selectedAccessType: selectedAccessType,
                                                         selectedSpace: selectedSpace)
        
        super.init(initialViewState: CreateRoomScreenViewState(isSpace: isSpace,
                                                               shouldShowCancelButton: shouldShowCancelButton,
                                                               roomName: "",
                                                               serverName: userSession.clientProxy.userIDServerName ?? "",
                                                               isKnockingFeatureEnabled: appSettings.knockingEnabled,
                                                               canSelectSpace: canSelectSpace,
                                                               aliasLocalPart: roomAliasNameFromRoomDisplayName(roomName: ""),
                                                               bindings: bindings),
                   mediaProvider: userSession.mediaProvider)
        
        state.requiresGroupParticipants = !isSpace && AntintwrkSocialDirectory.socialID(userSession.clientProxy.userID) != nil
        setupBindings()
        
        if canSelectSpace {
            Task {
                state.editableSpaces = await userSession.clientProxy.spaceService.editableSpaces()
            }
        }
    }
    
    // MARK: - Public
    
    override func process(viewAction: CreateRoomScreenViewAction) {
        switch viewAction {
        case .searchGroupPeople(let query):
            state.groupQuery = query
            groupSearchTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                state.isSearchingGroup = true
                let results = await userDiscoveryService.searchProfiles(with: query)
                guard !Task.isCancelled, state.groupQuery == query else { return }
                state.isSearchingGroup = false
                if case .success(let users) = results {
                    state.groupResults = users.filter { $0.id != userSession.clientProxy.userID && AntintwrkSocialDirectory.socialID($0.id) != nil }
                }
            }
        case .toggleGroupPerson(let user):
            guard user.id != userSession.clientProxy.userID, AntintwrkSocialDirectory.socialID(user.id) != nil else { return }
            if state.groupParticipants.contains(where: { $0.id == user.id }) {
                state.groupParticipants.removeAll { $0.id == user.id }
            } else {
                state.groupParticipants.append(user)
            }
        case .dismiss:
            actionsSubject.send(.dismiss)
        case .createRoom:
            Task { await createRoom() }
        case .displayCameraPicker:
            actionsSubject.send(.displayCameraPicker)
        case .displayMediaPicker:
            actionsSubject.send(.displayMediaPicker)
        case .displayFilePicker:
            actionsSubject.send(.displayFilePicker)
        case .removeImage:
            state.avatarMediaInfo = nil
        case .updateAliasLocalPart(let aliasLocalPart):
            state.aliasLocalPart = aliasLocalPart.lowercased()
            // If this has been called this means that the user wants a custom address not necessarily reflecting the name
            // So we disable the two from syncing.
            syncNameAndAlias = false
        case .updateRoomName(let name):
            // Reset the syncing if the name is fully cancelled
            if name.isEmpty {
                syncNameAndAlias = true
            }
            state.roomName = name
            if syncNameAndAlias {
                state.aliasLocalPart = roomAliasNameFromRoomDisplayName(roomName: name)
            }
        }
    }
    
    func updateAvatar(fileURL: URL) {
        showLoadingIndicator()
        Task { [weak self] in
            guard let self else { return }
            do {
                guard case let .success(maxUploadSize) = await userSession.clientProxy.maxMediaUploadSize else {
                    MXLog.error("Failed to get max upload size")
                    state.bindings.alertInfo = .init(id: .unknown)
                    return
                }
                let mediaInfo = try await mediaUploadingPreprocessor.processMedia(at: fileURL, maxUploadSize: maxUploadSize).get()
                
                switch mediaInfo {
                case .image:
                    state.avatarMediaInfo = mediaInfo
                default:
                    break
                }
            } catch {
                state.bindings.alertInfo = .init(id: .failedProcessingMedia)
            }
            hideLoadingIndicator()
        }
    }
    
    // MARK: - Private
    
    private func setupBindings() {
        // Reset the state related to public rooms if the user choses the room to be empty
        context.$viewState
            .dropFirst()
            .map(\.roomAccessType)
            .filter(\.isVisibilityPrivate)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                state.aliasErrors = []
                state.aliasLocalPart = roomAliasNameFromRoomDisplayName(roomName: state.roomName)
                syncNameAndAlias = true
            }
            .store(in: &cancellables)
        
        context.$viewState
            .map(\.aliasLocalPart)
            .removeDuplicates()
            .debounce(for: 1, scheduler: DispatchQueue.main)
            .sink { [weak self] aliasLocalPart in
                guard let self else {
                    return
                }
                
                guard !state.roomAccessType.isVisibilityPrivate,
                      let canonicalAlias = String.makeCanonicalAlias(aliasLocalPart: aliasLocalPart,
                                                                     serverName: state.serverName) else {
                    // While is empty or private room we don't change or display the error
                    return
                }
                
                if !isRoomAliasFormatValid(alias: canonicalAlias) {
                    state.aliasErrors.insert(.invalidSymbols)
                    // If the alias is invalid we don't need to check for availability
                    state.aliasErrors.remove(.alreadyExists)
                    checkAliasAvailabilityTask = nil
                    return
                }
                
                state.aliasErrors.remove(.invalidSymbols)
                
                checkAliasAvailabilityTask = Task { [weak self] in
                    guard let self else {
                        return
                    }
                    
                    if case .success(false) = await self.userSession.clientProxy.isAliasAvailable(canonicalAlias) {
                        guard !Task.isCancelled else { return }
                        state.aliasErrors.insert(.alreadyExists)
                    } else {
                        guard !Task.isCancelled else { return }
                        state.aliasErrors.remove(.alreadyExists)
                    }
                }
            }
            .store(in: &cancellables)
        
        context.$viewState
            .map(\.availableAccessTypes)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] availableAccessTypes in
                guard let self else { return }
                if !availableAccessTypes.contains(state.bindings.selectedAccessType) {
                    state.bindings.selectedAccessType = .private
                }
            }
            .store(in: &cancellables)
    }
    
    private func createRoom() async {
        guard !state.requiresGroupParticipants || Set(state.groupParticipants.map(\.id)).count >= 2 else { return }
        defer {
            hideLoadingIndicator()
        }
        showLoadingIndicator()
        
        // Better to double check the errors also when trying to create the room
        if !state.roomAccessType.isVisibilityPrivate {
            guard let canonicalAlias = String.makeCanonicalAlias(aliasLocalPart: state.aliasLocalPart,
                                                                 serverName: state.serverName),
                isRoomAliasFormatValid(alias: canonicalAlias) else {
                state.aliasErrors = [.invalidSymbols]
                return
            }
            
            switch await userSession.clientProxy.isAliasAvailable(canonicalAlias) {
            case .success(true):
                break
            case .success(false):
                state.aliasErrors = [.alreadyExists]
                return
            case .failure:
                state.bindings.alertInfo = AlertInfo(id: .unknown)
                return
            }
        }
        
        let avatarURL: URL?
        if let media = state.avatarMediaInfo {
            switch await userSession.clientProxy.uploadMedia(media) {
            case .success(let url):
                avatarURL = URL(string: url)
            case .failure(let error):
                switch error {
                case .failedUploadingMedia(let errorKind):
                    switch errorKind {
                    case .tooLarge:
                        state.bindings.alertInfo = AlertInfo(id: .fileTooLarge)
                    default:
                        state.bindings.alertInfo = AlertInfo(id: .failedUploadingMedia)
                    }
                case .invalidMedia:
                    state.bindings.alertInfo = AlertInfo(id: .mediaFileError)
                default:
                    state.bindings.alertInfo = AlertInfo(id: .unknown)
                }
                
                return
            }
        } else {
            avatarURL = nil
        }
        
        switch await userSession.clientProxy.createRoom(name: state.roomName,
                                                        topic: state.bindings.roomTopic.isBlank ? nil : state.bindings.roomTopic,
                                                        accessType: state.roomAccessType,
                                                        isSpace: state.isSpace,
                                                        userIDs: state.requiresGroupParticipants ? state.groupParticipants.map(\.id) : [],
                                                        avatarURL: avatarURL,
                                                        aliasLocalPart: state.roomAccessType.isVisibilityPrivate ? nil : state.aliasLocalPart) {
        case .success(let roomID):
            guard case let .joined(roomProxy) = await userSession.clientProxy.roomForIdentifier(roomID) else {
                state.bindings.alertInfo = AlertInfo(id: .failedCreatingRoom,
                                                     title: L10n.commonError,
                                                     message: L10n.screenStartChatErrorStartingChat)
                return
            }
            analytics.trackCreatedRoom(isDM: false)
            
            var spaceRoomListProxy: SpaceRoomListProxyProtocol?
            if state.isSpace {
                switch await userSession.clientProxy.spaceService.spaceRoomList(spaceID: roomID) {
                case .success(let value):
                    spaceRoomListProxy = value
                case .failure:
                    MXLog.error("Failed to get space room list for newly created space with id: \(roomID)")
                    userIndicatorController.submitIndicator(.init(title: L10n.errorUnknown))
                }
            }
            
            if let spaceID = state.bindings.selectedSpace?.id {
                await addRoomToSpace(roomProxy: roomProxy, spaceID: spaceID)
            }
            
            actionsSubject.send(.createdRoom(roomProxy, spaceRoomListProxy))
        case .failure:
            state.bindings.alertInfo = AlertInfo(id: .failedCreatingRoom,
                                                 title: L10n.commonError,
                                                 message: L10n.screenStartChatErrorStartingChat)
        }
    }
    
    private func addRoomToSpace(roomProxy: JoinedRoomProxyProtocol, spaceID: String) async {
        roomProxy.subscribeToRoomInfoUpdates()
        let runner = ExpiringTaskRunner { @MainActor in
            // Necessary to build the room cache so that the space can be added as a parent.
            _ = await roomProxy.infoPublisher.values.first { @Sendable in $0.powerLevels != nil }
        }
        
        do {
            try await runner.run(timeout: .seconds(30))
            if case .failure = await userSession.clientProxy.spaceService.addChild(roomProxy.id, to: spaceID) {
                MXLog.error("Failed to add the created room with id: \(roomProxy.id) to the space with id: \(spaceID)")
                userIndicatorController.submitIndicator(.init(title: L10n.errorUnknown))
            }
        } catch {
            MXLog.error("Timed out waiting for power levels to load for room with id: \(roomProxy.id)")
            userIndicatorController.submitIndicator(.init(title: L10n.errorUnknown))
        }
    }
    
    // MARK: Loading indicator
    
    private static let loadingIndicatorIdentifier = "\(CreateRoomScreenViewModel.self)-Loading"
    
    private func showLoadingIndicator() {
        userIndicatorController.submitIndicator(UserIndicator(id: Self.loadingIndicatorIdentifier,
                                                              type: .modal(progress: .indeterminate, interactiveDismissDisabled: true, allowsInteraction: false),
                                                              title: L10n.commonLoading,
                                                              persistent: true))
    }
    
    private func hideLoadingIndicator() {
        userIndicatorController.retractIndicatorWithId(Self.loadingIndicatorIdentifier)
    }
}
