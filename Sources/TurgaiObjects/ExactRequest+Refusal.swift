import ScopedEffect
import TurgaiDomain

extension ExactRequest {
    /// Its refusal where the scope it ran in doesn't allow it: why, and exactly what was refused,
    /// which whoever opened the scope asks the scope's space to allow. One that can't be written
    /// down says only why: no one is asked.
    public var refusal: EffectRefusal {
        guard let refused = encoded else { return EffectRefusal("not allowed in this scope: \(self)") }
        return EffectRefusal(
            "not allowed in this scope, so this space's admins are asked to allow it: \(self)", refused: refused)
    }

    /// What `refusal` refused, when it's an exact request.
    public init?(refusal: EffectRefusal) {
        self.init(encoded: refusal.refused)
    }
}
