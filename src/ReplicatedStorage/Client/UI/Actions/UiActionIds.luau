--!strict

local UiActionIds: any = {
	PointerEntered = "ui.pointer.entered",
	PointerExited = "ui.pointer.exited",
	ButtonActivated = "ui.button.activated",
	TextBoxFocused = "ui.textbox.focused",
	TextBoxUnfocused = "ui.textbox.unfocused",
	TextBoxConfirmed = "ui.textbox.confirmed",
	FormSubmitted = "ui.form.submitted",
	FormCancelled = "ui.form.cancelled",
	WindowOpened = "ui.window.opened",
	WindowPaused = "ui.window.paused",
	WindowResumed = "ui.window.resumed",
	WindowShown = "ui.window.shown",
	WindowHidden = "ui.window.hidden",
	WindowClosed = "ui.window.closed",
}

UiActionIds.Entries = table.freeze({
	table.freeze({ Name = "PointerEntered", Id = UiActionIds.PointerEntered }),
	table.freeze({ Name = "PointerExited", Id = UiActionIds.PointerExited }),
	table.freeze({ Name = "ButtonActivated", Id = UiActionIds.ButtonActivated }),
	table.freeze({ Name = "TextBoxFocused", Id = UiActionIds.TextBoxFocused }),
	table.freeze({ Name = "TextBoxUnfocused", Id = UiActionIds.TextBoxUnfocused }),
	table.freeze({ Name = "TextBoxConfirmed", Id = UiActionIds.TextBoxConfirmed }),
	table.freeze({ Name = "FormSubmitted", Id = UiActionIds.FormSubmitted }),
	table.freeze({ Name = "FormCancelled", Id = UiActionIds.FormCancelled }),
	table.freeze({ Name = "WindowOpened", Id = UiActionIds.WindowOpened }),
	table.freeze({ Name = "WindowPaused", Id = UiActionIds.WindowPaused }),
	table.freeze({ Name = "WindowResumed", Id = UiActionIds.WindowResumed }),
	table.freeze({ Name = "WindowShown", Id = UiActionIds.WindowShown }),
	table.freeze({ Name = "WindowHidden", Id = UiActionIds.WindowHidden }),
	table.freeze({ Name = "WindowClosed", Id = UiActionIds.WindowClosed }),
})

return table.freeze(UiActionIds)
