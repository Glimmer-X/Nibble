import NibbleCore
import SwiftUI

/// The reader's personas for the model APIs, in settings under the model: a chip for each (the one
/// in use lit) and one to add a persona; under them the persona in use, its name and its system
/// prompt each on a box of dim cells, with keys to delete it and to revert or save changes.
/// Unsaved changes are kept per persona while the page is open.
struct PersonaEditor: View {
    @Environment(AppModel.self) private var model
    @State private var drafts: [Persona.ID: Persona] = [:]
    @State private var confirmingDelete = false
    @FocusState private var focus: Focus?

    private enum Focus: Hashable {
        case name, prompt
    }

    var body: some View {
        let s = model.strings
        VStack(alignment: .leading, spacing: 12) {
            Flow(spacing: 8, lineSpacing: 8) {
                ForEach(model.personaChoices) { choice in
                    Choice(id: "persona-\(key(choice.pick))", title: choice.name, selected: choice.selected) {
                        confirmingDelete = false
                        model.choose(choice.pick)
                    }
                }
                Choice(id: "persona-add", title: "+ \(s.addPersona)", selected: false) {
                    confirmingDelete = false
                    model.addPersona()
                    DispatchQueue.main.async { focus = .name }
                }
            }
            if let persona = model.settings.currentPersona {
                editor(persona)
            } else {
                Text(s.noPersonaNote).pixelText().foregroundStyle(model.colors.ink3)
                    .frame(height: Typeface.keyHeight)
                    .padding(.leading, 8)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func editor(_ saved: Persona) -> some View {
        let s = model.strings
        let colors = model.colors
        let draft = drafts[saved.id] ?? saved
        let changed = draft != saved
        // A row of dark cells between the two boxes keeps them apart.
        VStack(alignment: .leading, spacing: 16) {
            TextField(s.personaNamePlaceholder, text: binding(saved, \.name))
                .textFieldStyle(.plain)
                .font(Typeface.message)
                .foregroundStyle(colors.ink)
                .focused($focus, equals: .name)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .boardPlate("persona-name", value: focus == .name ? 0.16 : 0.08, page: "main", clip: "body")

            ZStack(alignment: .topLeading) {
                // The hint leaves once the box has focus, so it never sits under text being composed.
                if draft.prompt.isEmpty && focus != .prompt {
                    Text(s.promptPlaceholder)
                        .font(Typeface.message)
                        .rhythm()
                        .foregroundStyle(colors.ink3)
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .allowsHitTesting(false)
                }
                TextEditor(text: binding(saved, \.prompt))
                    .font(Typeface.message)
                    .foregroundStyle(colors.ink)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .focused($focus, equals: .prompt)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 6)
            }
            .frame(minHeight: 128, maxHeight: 264)
            .contentShape(Rectangle())
            .onTapGesture { focus = .prompt }
            .boardPlate("persona-prompt", value: focus == .prompt ? 0.16 : 0.08, page: "main", clip: "body")

            HStack(spacing: 8) {
                TextKey(id: "persona-delete", title: confirmingDelete ? s.confirmDelete : s.delete, place: .main("body"),
                        tint: confirmingDelete ? colors.rose : nil) {
                    if confirmingDelete {
                        drafts[saved.id] = nil
                        confirmingDelete = false
                        model.deletePersona(saved.id)
                    } else {
                        confirmingDelete = true
                    }
                }
                Spacer(minLength: 0)
                if changed {
                    TextKey(id: "persona-revert", title: s.revert, place: .main("body")) {
                        drafts[saved.id] = nil
                    }
                    TextKey(id: "persona-save", title: s.save, place: .main("body"), tint: colors.accent) {
                        model.save(draft)
                        drafts[saved.id] = nil
                    }
                }
            }
            .padding(.horizontal, -8)
            .padding(.top, -6)
        }
        .onChange(of: saved.id) { confirmingDelete = false }
    }

    /// A field of the persona's draft.
    private func binding(_ saved: Persona, _ path: WritableKeyPath<Persona, String>) -> Binding<String> {
        Binding(
            get: { (drafts[saved.id] ?? saved)[keyPath: path] },
            set: { value in
                var draft = drafts[saved.id] ?? saved
                draft[keyPath: path] = value
                drafts[saved.id] = draft == saved ? nil : draft
            }
        )
    }

    private func key(_ pick: AppModel.PersonaChoice.Pick) -> String {
        switch pick {
        case .profile(let name): name
        case .persona(let id): id?.uuidString ?? "none"
        }
    }
}
