public import Foundation
@preconcurrency public import SwiftData

/// First-release schema. Just posts.
public enum PostsSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)
    public static let models: [any PersistentModel.Type] = [Post.self]

    @Model public final class Post {
        @Attribute(.unique) public var id: String
        public var title: String
        public var body: String
        public var createdAt: Date

        public init(id: String, title: String, body: String, createdAt: Date) {
            self.id = id
            self.title = title
            self.body = body
            self.createdAt = createdAt
        }
    }
}
