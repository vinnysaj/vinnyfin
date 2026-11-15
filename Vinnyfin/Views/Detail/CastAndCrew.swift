import SwiftUI

/// A title's people as its page lists them: the cast in billing order, then the crew that made it,
/// its creators, directors and writers, each person once in each.
nonisolated struct Credits: Equatable, Sendable {
    /// Someone on the title: an actor with the parts they played, or a member of the crew with
    /// the jobs they did.
    struct Credit: Identifiable, Hashable, Sendable {
        let person: Person
        /// The parts an actor played.
        var roles: [String] = []
        /// What a member of the crew did, as `crewJobs` names it.
        var jobs: [String] = []

        var isCrew: Bool { !jobs.isEmpty }

        /// Someone in the cast and the crew both, as an actor who directed, is in each once.
        var id: String { (isCrew ? "crew." : "cast.") + person.id }

        /// The parts, "Ada" or "Ada / Bea"; or the jobs, "Director" or "Director, Writer".
        var detail: String? {
            let parts = isCrew ? jobs.joined(separator: ", ") : roles.joined(separator: " / ")
            return parts.isEmpty ? nil : parts
        }
    }

    /// The jobs the crew is listed for, in the order they're named.
    static let crewJobs = ["Creator", "Director", "Writer"]

    let cast: [Credit]
    let crew: [Credit]

    init(people: [Person]) {
        var cast: [(person: Person, roles: [String])] = []
        var crew: [(person: Person, jobs: Set<String>)] = []
        for person in people {
            switch person.type {
            case "Actor", "GuestStar":
                let role = person.role?.trimmingCharacters(in: .whitespaces) ?? ""
                if let index = cast.firstIndex(where: { $0.person.id == person.id }) {
                    if !role.isEmpty, !cast[index].roles.contains(role) { cast[index].roles.append(role) }
                } else {
                    cast.append((person, role.isEmpty ? [] : [role]))
                }
            case let job? where Self.crewJobs.contains(job):
                if let index = crew.firstIndex(where: { $0.person.id == person.id }) {
                    crew[index].jobs.insert(job)
                } else {
                    crew.append((person, [job]))
                }
            default:
                break
            }
        }
        self.cast = cast.map { Credit(person: $0.person, roles: $0.roles) }
        // Creators first, then directors, then writers, each in the server's order.
        self.crew = crew
            .enumerated()
            .sorted { left, right in
                let leftRank = Self.crewJobs.firstIndex { left.element.jobs.contains($0) } ?? Self.crewJobs.count
                let rightRank = Self.crewJobs.firstIndex { right.element.jobs.contains($0) } ?? Self.crewJobs.count
                return leftRank != rightRank ? leftRank < rightRank : left.offset < right.offset
            }
            .map { entry in Credit(person: entry.element.person, jobs: Self.crewJobs.filter { entry.element.jobs.contains($0) }) }
    }

    /// The most of the cast the page lists, so a show's long cast doesn't push its crew out of reach.
    static let listedCast = 20

    /// The leading cast, then the crew.
    var listed: [Credit] { Array(cast.prefix(Self.listedCast)) + crew }
    var isEmpty: Bool { cast.isEmpty && crew.isEmpty }

    /// The crew who did `job`, in the order they're listed.
    func people(doing job: String) -> [Person] {
        crew.filter { $0.jobs.contains(job) }.map(\.person)
    }
}

/// A title's Cast & Crew: its leading cast, then those who made it, each leading to their page.
struct CastAndCrewShelf: View {
    let credits: Credits

    var body: some View {
        if !credits.isEmpty {
            Shelf(title: credits.crew.isEmpty ? "Cast" : credits.cast.isEmpty ? "Crew" : "Cast & Crew",
                  items: credits.listed, cardWidth: PersonCard.width) { credit in
                NavigationLink(value: credit.person) {
                    PersonCard(person: credit.person, detail: credit.detail)
                }
                .buttonStyle(.artwork)
                .foregroundStyle(.primary)
            }
        }
    }
}
