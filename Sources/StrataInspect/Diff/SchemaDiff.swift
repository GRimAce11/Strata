public import StrataCore
public import SwiftData
public import Foundation

/// Structural diff between two declared SwiftData schemas.
///
/// `SchemaDiff` operates on the `Schema` metadata that SwiftData
/// derives from `@Model` types — it does **not** touch the on-disk
/// store. Use ``StoreIntrospector`` for that.
///
/// The diff is intentionally conservative: it reports presence
/// changes (model added/removed, attribute added/removed,
/// relationship added/removed) and basic shape changes (type,
/// nullability). It does **not** guess at semantic intent (e.g.
/// rename inference) — Strata's design principle is that renames
/// are user-declared, not heuristically inferred.
public struct SchemaDiff: Sendable, Equatable {
    public let from: String
    public let to: String
    public let changes: [Change]

    /// One observable difference between two schemas.
    public enum Change: Sendable, Equatable {
        case modelAdded(name: String)
        case modelRemoved(name: String)
        case attributeAdded(model: String, name: String, type: String)
        case attributeRemoved(model: String, name: String)
        case attributeTypeChanged(model: String, name: String, from: String, to: String)
        case attributeNullabilityChanged(model: String, name: String, fromOptional: Bool, toOptional: Bool)
        case attributeUniquenessChanged(model: String, name: String, fromUnique: Bool, toUnique: Bool)
        case relationshipAdded(model: String, name: String)
        case relationshipRemoved(model: String, name: String)
    }

    public var isEmpty: Bool { changes.isEmpty }

    /// Diff two `VersionedSchema` types.
    public static func diff(
        from: any VersionedSchema.Type,
        to: any VersionedSchema.Type
    ) -> SchemaDiff {
        let fromSchema = Schema(versionedSchema: from)
        let toSchema   = Schema(versionedSchema: to)
        return diff(
            from: fromSchema, to: toSchema,
            fromLabel: String(describing: from),
            toLabel: String(describing: to)
        )
    }

    /// Diff two already-constructed `Schema` values.
    public static func diff(
        from: Schema,
        to: Schema,
        fromLabel: String = "from",
        toLabel: String = "to"
    ) -> SchemaDiff {
        let fromEntities = Dictionary(uniqueKeysWithValues: from.entities.map { ($0.name, $0) })
        let toEntities   = Dictionary(uniqueKeysWithValues: to.entities.map { ($0.name, $0) })

        var changes: [Change] = []

        for added in toEntities.keys where fromEntities[added] == nil {
            changes.append(.modelAdded(name: added))
        }
        for removed in fromEntities.keys where toEntities[removed] == nil {
            changes.append(.modelRemoved(name: removed))
        }

        for (name, fromEntity) in fromEntities {
            guard let toEntity = toEntities[name] else { continue }
            changes.append(contentsOf: diffEntity(model: name, from: fromEntity, to: toEntity))
        }

        return SchemaDiff(
            from: fromLabel,
            to: toLabel,
            changes: changes.sorted { lhs, rhs in
                String(describing: lhs) < String(describing: rhs)
            }
        )
    }

    private static func diffEntity(
        model: String,
        from: Schema.Entity,
        to: Schema.Entity
    ) -> [Change] {
        var changes: [Change] = []

        // Attributes — Schema.Entity exposes these as Set<Schema.Attribute>
        // plus an `attributesByName` dictionary that's most convenient here.
        let fromAttrs = from.attributesByName
        let toAttrs   = to.attributesByName

        for (name, attr) in toAttrs where fromAttrs[name] == nil {
            changes.append(.attributeAdded(
                model: model, name: name, type: String(describing: attr.valueType)
            ))
        }
        for (name, _) in fromAttrs where toAttrs[name] == nil {
            changes.append(.attributeRemoved(model: model, name: name))
        }
        for (name, fromAttr) in fromAttrs {
            guard let toAttr = toAttrs[name] else { continue }
            let fromType = String(describing: fromAttr.valueType)
            let toType   = String(describing: toAttr.valueType)
            if fromType != toType {
                changes.append(.attributeTypeChanged(
                    model: model, name: name, from: fromType, to: toType
                ))
            }
            if fromAttr.isOptional != toAttr.isOptional {
                changes.append(.attributeNullabilityChanged(
                    model: model, name: name,
                    fromOptional: fromAttr.isOptional, toOptional: toAttr.isOptional
                ))
            }
            if fromAttr.isUnique != toAttr.isUnique {
                changes.append(.attributeUniquenessChanged(
                    model: model, name: name,
                    fromUnique: fromAttr.isUnique, toUnique: toAttr.isUnique
                ))
            }
        }

        // Relationships
        let fromRels = from.relationshipsByName
        let toRels   = to.relationshipsByName
        for (name, _) in toRels where fromRels[name] == nil {
            changes.append(.relationshipAdded(model: model, name: name))
        }
        for (name, _) in fromRels where toRels[name] == nil {
            changes.append(.relationshipRemoved(model: model, name: name))
        }

        return changes
    }
}
