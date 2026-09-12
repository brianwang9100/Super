// GRDBQuery's protocol uses Combine; observation is owned by @Query.
import Combine
import GRDB
import GRDBQuery

struct BibleWorkspaceDecorations: Equatable {
    var isLoaded = false
    var highlights: [BibleHighlightRecord] = []
    var annotations: [BibleAnnotationRecord] = []
    var notes: [BibleNoteRecord] = []
}

struct BibleWorkspaceDecorationsRequest: ValueObservationQueryable {
    static var defaultValue: BibleWorkspaceDecorations { .init() }
    let positions: [BiblePosition]

    func fetch(_ db: Database) throws -> BibleWorkspaceDecorations {
        var result = BibleWorkspaceDecorations(isLoaded: true)
        for position in positions {
            let condition = Column("bookId") == position.bookId && Column("chapterNumber") == position.chapterNumber
            result.highlights += try BibleHighlightRecord.filter(condition).filter(Column("deletedAt") == nil).fetchAll(db)
            result.annotations += try BibleAnnotationRecord.filter(condition).order(Column("createdAt"), Column("id")).fetchAll(db)
            result.notes += try BibleNoteRecord.filter(condition).order(Column("createdAt"), Column("id")).fetchAll(db)
        }
        return result
    }
}
