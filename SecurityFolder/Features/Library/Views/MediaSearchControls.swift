import SwiftUI

struct MediaSearchFiltersView: View {
    @Binding var query: MediaSearchQuery
    @Environment(\.dismiss) private var dismiss
    @State private var draft = MediaSearchQuery()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(String(localized: "媒体类型"), selection: $draft.type) {
                        ForEach(MediaSearchType.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                Section {
                    Toggle(String(localized: "按日期筛选"), isOn: $draft.usesDateRange)
                    if draft.usesDateRange {
                        Picker(String(localized: "日期依据"), selection: $draft.dateField) {
                            ForEach(MediaSearchDateField.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        DatePicker(String(localized: "开始日期"), selection: $draft.startDate, displayedComponents: .date)
                        DatePicker(String(localized: "结束日期"), selection: $draft.endDate, in: draft.startDate..., displayedComponents: .date)
                    }
                } footer: {
                    if draft.usesDateRange && draft.dateField == .captured {
                        Text(String(localized: "按拍摄日期筛选时，不包含缺少拍摄时间的项目。"))
                    }
                }
                Button(String(localized: "清除筛选")) {
                    let text = draft.text
                    draft = MediaSearchQuery()
                    draft.text = text
                }
            }
            .navigationTitle(String(localized: "筛选"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "应用")) { query = draft; dismiss() }
                        .disabled(draft.usesDateRange && draft.startDate > draft.endDate)
                }
            }
            .onAppear { draft = query }
            .onChange(of: draft.startDate) { _, date in
                if draft.endDate < date { draft.endDate = date }
            }
        }
    }
}

struct MediaSearchToolbarStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.searchToolbarBehavior(.minimize)
        } else {
            content
        }
    }
}

struct MediaSearchFieldStyle: ViewModifier {
    @Binding var text: String
    let placement: SearchFieldPlacement
    let prompt: String
    let focus: FocusState<Bool>.Binding
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .searchable(text: $text, placement: placement, prompt: prompt)
                .modifier(MediaSearchToolbarStyle())
                .searchPresentationToolbarBehavior(.avoidHidingContent)
                .searchFocused(focus)
        } else {
            content
        }
    }
}
