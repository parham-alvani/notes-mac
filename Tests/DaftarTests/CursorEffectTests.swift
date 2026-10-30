import AppKit
import Foundation
import Testing

@testable import DaftarUI

/// Neovim mode's cursor as Neovide moves it: the corners of its trail, and
/// the particles of its effects.
@Suite struct CursorEffectTests {
    let from = NSRect(x: 0, y: 0, width: 8, height: 16)
    let to = NSRect(x: 200, y: 0, width: 8, height: 16)

    @Test func theFrontCornersGoFirstAndAllArrive() {
        var trail = CursorTrail(from)
        trail.move(to: to, at: 0, trail: true, short: false)
        let moving = trail.step(at: CursorTrail.length / 2)
        #expect(moving)
        // Moving right: the right corners (1, 2) are ahead of the left ones.
        #expect(trail.corners[1].x > trail.corners[0].x + to.width)
        #expect(trail.corners[2].x > trail.corners[3].x + to.width)
        #expect(trail.bounds.width > to.width)
        let still = !trail.step(at: CursorTrail.length)
        #expect(still && trail.bounds == to)
    }

    @Test func withoutATrailTheCursorKeepsItsShape() {
        var trail = CursorTrail(from)
        trail.move(to: to, at: 0, trail: false, short: false)
        _ = trail.step(at: CursorTrail.length / 3)
        #expect(abs(trail.bounds.width - to.width) < 0.001)
        // A short move is over in a moment.
        trail.move(to: from, at: 1, trail: true, short: true)
        let over = !trail.step(at: 1 + CursorTrail.short)
        #expect(over && trail.bounds == from)
    }

    @Test func eachEffectMakesItsParticlesAndTheyFade() {
        var particles = CursorParticles()
        particles.random = { 0.5 }
        particles.spawn(.none, from: from, to: to)
        #expect(particles.particles.isEmpty)
        for effect in [AppSettings.CursorEffect.railgun, .torpedo, .pixiedust] {
            var some = particles
            some.spawn(effect, from: from, to: to)
            #expect(some.particles.count >= 4 && some.particles.count <= CursorParticles.most, "\(effect)")
            #expect(some.particles.allSatisfy { $0.shape == .dot })
        }
        particles.spawn(.sonicboom, from: from, to: to)
        particles.spawn(.ripple, from: from, to: to)
        #expect(particles.particles.map(\.shape) == [.box(to), .circle(to.height * 2)])
        particles.step(by: 0.2)
        #expect(particles.particles.allSatisfy { $0.strength < 1 && $0.strength > 0 })
        particles.step(by: 1)
        #expect(particles.particles.isEmpty)
    }

    @Test func aLongWayHasNoMoreThanTheMost() {
        var particles = CursorParticles()
        for _ in 0..<5 { particles.spawn(.railgun, from: from, to: NSRect(x: 5000, y: 3000, width: 8, height: 16)) }
        #expect(particles.particles.count == CursorParticles.most)
    }

    @MainActor @Test func theNeovideSettingsAreInTheFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "daftar-vfx-\(UUID().uuidString)/config.toml")
        let settings = AppSettings(url: url)
        #expect(settings.cursorTrail && settings.cursorEffect == .none && settings.optionAsMeta == .none && settings.blurPanels)
        settings.cursorTrail = false
        settings.cursorEffect = .pixiedust
        settings.optionAsMeta = .left
        settings.blurPanels = false
        let again = AppSettings(url: url)
        #expect(!again.cursorTrail && again.cursorEffect == .pixiedust && again.optionAsMeta == .left && !again.blurPanels)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
