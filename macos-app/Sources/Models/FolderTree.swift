// FolderTree.swift
//
// Baumstruktur fuer Ordner, gebaut aus einem flachen FolderDTO-Array.
// Wird von der UI genutzt, um verschachtelte Ordner darzustellen.
//
// Robustheit:
// - Verwaiste Ordner (parent_folder_id gesetzt, Elter existiert nicht) werden als Wurzeln behandelt.
// - Zyklen (A->B->A) werden erkannt und abgeschnitten: die Vorfahren-Menge wird pro Zweig
//   mitgefuehrt, ein Knoten der bereits in der Kette liegt wird nicht noch einmal eingebaut.
// - Geschwister werden nach sort_order (nil zuletzt) dann nach name sortiert.

import Foundation

/// Ein Knoten im Ordnerbaum. Wert-Typ, Sendable.
struct FolderNode: Identifiable, Sendable {
    let id: String
    let name: String
    let videoCount: Int
    var children: [FolderNode]
}

extension FolderNode {

    /// Baut eine Baum-Hierarchie aus einem flachen FolderDTO-Array.
    /// - Parameter flat: alle Ordner eines Projekts in beliebiger Reihenfolge.
    /// - Returns: sortierte Wurzel-Knoten mit rekursiv eingebauten Kindern.
    static func buildTree(from flat: [FolderDTO]) -> [FolderNode] {
        let allIDs = Set(flat.map { $0.id })

        // Kinder-Map: parent_folder_id -> [child-DTOs]
        let childrenMap: [String: [FolderDTO]] = flat.reduce(into: [:]) { acc, dto in
            let parentID = dto.parent_folder_id ?? ""
            guard !parentID.isEmpty, allIDs.contains(parentID) else { return }
            acc[parentID, default: []].append(dto)
        }

        // Wurzeln: kein parent, leerer parent, oder parent existiert nicht im Set.
        let roots = flat.filter { dto in
            let parentID = dto.parent_folder_id ?? ""
            return parentID.isEmpty || !allIDs.contains(parentID)
        }

        // Vergleichsfunktion fuer Geschwister: sort_order aufsteigend (nil zuletzt), dann name.
        func folderOrder(_ a: FolderDTO, _ b: FolderDTO) -> Bool {
            let ao = a.sort_order
            let bo = b.sort_order
            if let ai = ao, let bi = bo { return ai != bi ? ai < bi : a.name < b.name }
            if ao != nil { return true }  // a hat Wert, b hat nil -> a zuerst
            if bo != nil { return false } // b hat Wert, a hat nil -> b zuerst
            return a.name < b.name        // beide nil -> alphabetisch
        }

        // Rekursiver Knotenbau. ancestorIDs enthaelt alle Vorfahren-IDs auf dem aktuellen Pfad,
        // inklusive des aktuellen Knotens - verhindert Endlosrekursion bei Zyklen.
        func buildNodes(parentID: String, ancestorIDs: Set<String>) -> [FolderNode] {
            guard let childDTOs = childrenMap[parentID] else { return [] }
            return childDTOs
                .sorted(by: folderOrder)
                .compactMap { dto -> FolderNode? in
                    guard !ancestorIDs.contains(dto.id) else { return nil } // Zyklus-Stopp
                    let children = buildNodes(
                        parentID: dto.id,
                        ancestorIDs: ancestorIDs.union([dto.id])
                    )
                    return FolderNode(
                        id: dto.id,
                        name: dto.name,
                        videoCount: dto.video_count ?? 0,
                        children: children
                    )
                }
        }

        return roots
            .sorted(by: folderOrder)
            .map { dto in
                FolderNode(
                    id: dto.id,
                    name: dto.name,
                    videoCount: dto.video_count ?? 0,
                    children: buildNodes(parentID: dto.id, ancestorIDs: [dto.id])
                )
            }
    }
}
