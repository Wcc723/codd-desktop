/// Server instructions sent in `initialize`. English (the model's working language for tool
/// use), at most 4,096 characters because Claude Code cuts server instructions there (tested).
/// With tool search on, this text and the tool names are what loads at startup, so it says when
/// to reach for the notes at all (and, since notes_create, when to write a document into them).
public enum MCPInstructions {
    public static let notes = """
        CODD is the user's local notebook for their Claude Code work: Markdown notes, often written in \
        Traditional Chinese (繁體中文), with pasted screenshots and image annotations. These tools read it \
        and add to it.

        - A note reference looks like codd://note/<id>, [[note:<id>]] or @codd:codd://note/<id>. When the \
        user's message contains one, call notes_read with that ref before you answer, unless the message \
        already carries the note in a <codd-note ref="codd://note/<id>"> block (CODD expands references in \
        the sessions it launches; then do not read it again).
        - notes_search finds notes by words (short Chinese terms of one or two characters work too), \
        "quoted phrases" and #tags. notes_list lists recent notes, notes linked to the current session \
        (session: "current") or project (project: "current"), pinned notes and prompts.
        - notes_read returns the note text with absolute file paths, followed by its images as image \
        blocks. Image annotations are listed under each image as numbered items in ORIGINAL image pixels, \
        origin at the top-left (rect x= y= w= h=, point x= y=, arrow from x,y to x2,y2, text at x= y=); \
        refer to them by number. \
        Long notes come in pages: call notes_read again with the offset it reports.
        - notes_append adds a section at the end of a note. It works only on notes whose AI access is \
        APPEND; READ notes refuse it, and the user may be asked to approve each append. notes_write, \
        when offered, replaces a note's body and always asks the user; prefer notes_append.
        - notes_create writes a NEW note into the notebook's INBOX, linked to this session and its project, \
        for the user to read in CODD. When the user asks you to put a document (a report, a plan, a review, \
        a summary) in CODD or in their notes, use it instead of writing a Markdown file into the project. \
        Give a short title and the Markdown body without the title line. It never changes an existing \
        note; the new note's AI access is APPEND, so add to it later with notes_append and its ref. The user \
        may be asked to approve each create.
        - Some notes are hidden from AI on purpose, and trashed notes must be restored by the user first. \
        If a note cannot be found or read, say so and ask the user. Never guess or invent what a note \
        says, and never claim you saved something to a note unless the call succeeded.
        """
}
