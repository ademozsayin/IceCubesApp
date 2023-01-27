import Foundation
import Models
import Network
import SwiftUI

@MainActor
class NotificationsViewModel: ObservableObject {
  public enum State {
    public enum PagingState {
      case none, hasNextPage, loadingNextPage
    }

    case loading
    case display(notifications: [ConsolidatedNotification], nextPageState: State.PagingState)
    case error(error: Error)
  }

  public enum Tab: LocalizedStringKey, CaseIterable {
    case all = "notifications.tab.all"
    case mentions = "notifications.tab.mentions"
  }

  var client: Client? {
    didSet {
      if oldValue != client {
        consolidatedNotifications = []
      }
    }
  }

  @Published var state: State = .loading
  @Published var selectedType: Models.Notification.NotificationType? {
    didSet {
      if oldValue != selectedType {
        consolidatedNotifications = []
        Task {
          await fetchNotifications()
        }
      }
    }
  }

  private var queryTypes: [String]? {
    if let selectedType {
      var excludedTypes = Models.Notification.NotificationType.allCases
      excludedTypes.removeAll(where: { $0 == selectedType })
      return excludedTypes.map { $0.rawValue }
    }
    return nil
  }

  private var consolidatedNotifications: [ConsolidatedNotification] = []

  func fetchNotifications() async {
    guard let client else { return }
    do {
      var nextPageState: State.PagingState = .hasNextPage
      if consolidatedNotifications.isEmpty {
        state = .loading
        let notifications: [Models.Notification] =
          try await client.get(endpoint: Notifications.notifications(sinceId: nil,
                                                                     maxId: nil,
                                                                     types: queryTypes))
        consolidatedNotifications = notifications.consolidated()
        nextPageState = notifications.count < 15 ? .none : .hasNextPage
      } else if let first = consolidatedNotifications.first {
        var newNotifications: [Models.Notification] =
          try await client.get(endpoint: Notifications.notifications(sinceId: first.id,
                                                                     maxId: nil,
                                                                     types: queryTypes))
        nextPageState = consolidatedNotifications.notificationCount < 15 ? .none : .hasNextPage
        newNotifications = newNotifications.filter { notification in
          !consolidatedNotifications.contains(where: { $0.id == notification.id })
        }
        consolidatedNotifications.insert(contentsOf: newNotifications.consolidated(), at: 0)
      }
      withAnimation {
        state = .display(notifications: consolidatedNotifications,
                         nextPageState: consolidatedNotifications.isEmpty ? .none : nextPageState)
      }
    } catch {
      state = .error(error: error)
    }
  }

  func fetchNextPage() async {
    guard let client else { return }
    do {
      guard let lastId = consolidatedNotifications.last?.id else { return }
      state = .display(notifications: consolidatedNotifications, nextPageState: .loadingNextPage)
      let newNotifications: [Models.Notification] =
        try await client.get(endpoint: Notifications.notifications(sinceId: nil,
                                                                   maxId: lastId,
                                                                   types: queryTypes))
      consolidatedNotifications.append(contentsOf: newNotifications.consolidated())
      state = .display(notifications: consolidatedNotifications, nextPageState: newNotifications.count < 15 ? .none : .hasNextPage)
    } catch {
      state = .error(error: error)
    }
  }

  func clear() async {
    guard let client else { return }
    do {
      let _: ServerError = try await client.post(endpoint: Notifications.clear)
    } catch {}
  }

  func handleEvent(event: any StreamEvent) {
    if let event = event as? StreamEventNotification,
       !consolidatedNotifications.contains(where: { $0.id == event.notification.id })
    {
      if let selectedType, event.notification.type == selectedType.rawValue {
        consolidatedNotifications.insert(contentsOf: [event.notification].consolidated(),
                                         at: 0)
      } else if selectedType == nil {
        consolidatedNotifications.insert(contentsOf: [event.notification].consolidated(),
                                         at: 0)
      }
      state = .display(notifications: consolidatedNotifications, nextPageState: .hasNextPage)
    }
  }
}

struct ConsolidatedNotification: Identifiable {
  let id: String
  let type: Models.Notification.NotificationType
  let createdAt: ServerDate
  let accounts: [Account]
  let status: Status?

  static func placeholder() -> ConsolidatedNotification {
    .init(id: UUID().uuidString,
          type: .favourite,
          createdAt: "2022-12-16T10:20:54.000Z",
          accounts: [.placeholder()],
          status: .placeholder())
  }

  static func placeholders() -> [ConsolidatedNotification] {
    [.placeholder(), .placeholder(), .placeholder(), .placeholder(), .placeholder(), .placeholder(), .placeholder(), .placeholder()]
  }
}

extension Array where Element == Models.Notification {
  func consolidated() -> [ConsolidatedNotification] {
    Dictionary(grouping: self) { notification -> String? in
      guard let supportedType = notification.supportedType else { return nil }

      switch supportedType {
      case .follow:
        // Always group followers
        return supportedType.rawValue
      case .reblog, .favourite:
        // Group boosts and favourites by status
        return "\(supportedType.rawValue)-\(notification.status?.id ?? "")"
      case .follow_request, .poll, .status, .update, .mention:
        // Never group those
        return notification.id
      }
    }
    .values
    .compactMap { notifications in
      guard let notification = notifications.first,
            let supportedType = notification.supportedType
      else { return nil }

      return ConsolidatedNotification(id: notification.id,
                                      type: supportedType,
                                      createdAt: notification.createdAt,
                                      accounts: notifications.map(\.account),
                                      status: notification.status)
    }
    .sorted {
      $0.createdAt > $1.createdAt
    }
  }
}

extension Array where Element == ConsolidatedNotification {
  var notificationCount: Int {
    reduce(0) { $0 + ($1.accounts.isEmpty ? 1 : $1.accounts.count) }
  }
}
