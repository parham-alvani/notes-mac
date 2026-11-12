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

    /// A glide that goes on with the view's scroll: from where the corners
    /// are, all together, to the same place, in the scroll's time.
    @Test func aGlideGoesWithTheScroll() {
        var trail = CursorTrail(from)
        trail.move(to: to, at: 0, trail: true, short: false)
        _ = trail.step(at: 0.02)
        let stretched = trail.bounds.width
        trail.retime(at: 0.02, length: 0.12)
        let halfway = trail.step(at: 0.02 + 0.06)
        #expect(halfway)
        // All four corners go the same part of the way: the stretch only shrinks.
        #expect(trail.bounds.width < stretched && trail.bounds.width > to.width)
        let still = !trail.step(at: 0.02 + 0.121)
        #expect(still)
        #expect(trail.bounds == to)
    }

    /// Text laid out again under a glide moves the whole way with it.
    @Test func aGlideMovesWithTheText() {
        var trail = CursorTrail(from)
        trail.move(to: to, at: 0, trail: true, short: false)
        _ = trail.step(at: CursorTrail.length / 2)
        let before = trail.bounds
        trail.shift(to: to.offsetBy(dx: 0, dy: 30))
        #expect(trail.bounds == before.offsetBy(dx: 0, dy: 30))
        _ = trail.step(at: CursorTrail.length)
        #expect(trail.bounds == to.offsetBy(dx: 0, dy: 30))
    }

    /// The cursor never trails the text: typing and a key held down move it
    /// at once; a jump in normal mode glides, with the particles.
    @Test func onlyAJumpGlides() {
        let block = NSRect(x: 100, y: 100, width: 8, height: 17)
        func moved(dx: CGFloat, dy: CGFloat) -> NSRect { block.offsetBy(dx: dx, dy: dy) }
        func motion(_ to: NSRect, normal: Bool = true, repeating: Bool = false, animate: Bool = true, effects: Bool = true) -> CursorMotion {
            CursorMotion.of(from: block, to: to, normal: normal, repeating: repeating, animate: animate, effects: effects)
        }
        // Normal mode: a word (w), a line (j), a paragraph away glide with particles.
        #expect(motion(moved(dx: 60, dy: 0)) == CursorMotion(glide: true, effect: true))
        #expect(motion(moved(dx: 0, dy: 27)) == CursorMotion(glide: true, effect: true))
        #expect(motion(moved(dx: -300, dy: 400)) == CursorMotion(glide: true, effect: true))
        // A letter to the side (h, l, x) is at once.
        #expect(motion(moved(dx: 8, dy: 0)) == .still)
        #expect(motion(moved(dx: -9, dy: 0)) == .still)
        // A key held down: at once, however far, and no particles.
        #expect(motion(moved(dx: 0, dy: 27), repeating: true) == .still)
        #expect(motion(moved(dx: 60, dy: 0), repeating: true) == .still)
        // Typing: a letter, a wrapped line, Return are at once, and never particles.
        let bar = NSRect(x: 100, y: 100, width: 2, height: 17)
        func typed(_ to: NSRect) -> CursorMotion {
            CursorMotion.of(from: bar, to: to, normal: false, repeating: false, animate: true, effects: true)
        }
        #expect(typed(bar.offsetBy(dx: 8, dy: 0)) == .still)
        #expect(typed(NSRect(x: 0, y: 127, width: 2, height: 17)) == .still)
        #expect(typed(NSRect(x: 0, y: 140, width: 2, height: 17)) == .still)
        #expect(typed(bar.offsetBy(dx: -8, dy: 0)) == .still)
        // A jump while typing (<C-o>G) glides, without particles.
        #expect(typed(NSRect(x: 0, y: 600, width: 2, height: 17)) == CursorMotion(glide: true, effect: false))
        // The settings: no glide with animate_cursor off, no particles with cursor_effect none.
        #expect(motion(moved(dx: 0, dy: 27), animate: false) == CursorMotion(glide: false, effect: true))
        #expect(motion(moved(dx: 0, dy: 27), effects: false) == CursorMotion(glide: true, effect: false))
    }

    /// A key repeat is the event's flag, or one key pressed again within
    /// `KeyRepeat.gap`; it lasts a moment after its last key, not for ever.
    @Test func aKeyHeldDownIsARepeat() {
        var keys = KeyRepeat()
        keys.key(38, at: 10, isRepeat: false)
        #expect(!keys.held(at: 10.01))
        keys.key(38, at: 10.5, isRepeat: true)
        #expect(keys.held(at: 10.51))
        #expect(!keys.held(at: 10.5 + KeyRepeat.lasts + 0.01))
        // Thirty a second, with no flag (a made-up event).
        var made = KeyRepeat()
        made.key(38, at: 20, isRepeat: false)
        made.key(38, at: 20.033, isRepeat: false)
        #expect(made.held(at: 20.04))
        #expect(made.pressed && !KeyRepeat().pressed)
        #expect(made.pressed && !KeyRepeat().pressed)
        // Two keys typed quickly are not a repeat, nor one key pressed twice slowly.
        made.key(40, at: 20.06, isRepeat: false)
        #expect(!made.held(at: 20.07))
        made.key(40, at: 20.3, isRepeat: false)
        #expect(!made.held(at: 20.31))
    }

    /// One effect at a time in the view: a new move's particles replace the last one's.
    @MainActor @Test func oneEffectAtATime() {
        let view = CursorEffectsView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.spawn(.railgun, from: from, to: to)
        let one = view.particles.particles.count
        for _ in 0..<5 { view.spawn(.railgun, from: from, to: to) }
        #expect(view.particles.particles.count == one)
        view.spawn(.sonicboom, from: from, to: to)
        #expect(view.particles.particles.count == 1)
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
