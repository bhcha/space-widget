import Foundation
import Combine

final class SpaceLayoutBridge {
    private let spaceMonitor: SpaceMonitor
    private let store: LayoutTemplateStore
    private let applier: LayoutApplier
    private var cancellable: AnyCancellable?
    private var pendingApply: DispatchWorkItem?

    init(spaceMonitor: SpaceMonitor, store: LayoutTemplateStore, applier: LayoutApplier) {
        self.spaceMonitor = spaceMonitor
        self.store = store
        self.applier = applier
        observe()
    }

    private func observe() {
        cancellable = spaceMonitor.$currentSpace
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] space in
                guard let self = self else { return }

                // Cancel any pending apply from a previous space change
                self.pendingApply?.cancel()
                self.pendingApply = nil

                guard self.store.autoApplyEnabled,
                      space.id != 0
                else { return }

                let targetOrdinal = space.ordinal
                let work = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    let currentSpace = self.spaceMonitor.currentSpace
                    guard currentSpace.ordinal == targetOrdinal,
                          let template = self.store.templateForSpace(targetOrdinal)
                    else { return }
                    self.applier.apply(template, launchClosedApps: self.store.launchClosedApps)
                }
                self.pendingApply = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            }
    }
}
