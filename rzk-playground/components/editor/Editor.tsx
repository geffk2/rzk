'use client';

import CodeMirror from '@uiw/react-codemirror';
import { EditorView, keymap } from '@codemirror/view'
import { scrollPastEnd } from '@codemirror/view';
import { example } from './example';
import { color, oneDark } from './theme';
import { Dispatch, SetStateAction, useState } from 'react';
import { centerCursor } from './cursor-height';

export default function Editor({
    setText,
    setNeedTypecheck,
    editorHeight
}: {
    setText: Dispatch<SetStateAction<string>>,
    setNeedTypecheck: React.Dispatch<React.SetStateAction<boolean>>,
    editorHeight: number
}) {
    const [existsSelection, setExistsSelection] = useState(false)
    return <CodeMirror
        value={example}
        height={`100vh`}
        width={`100vw`}
        onCreateEditor={(view) => {
            setText(example)
            view.dispatch({ effects: EditorView.scrollIntoView(0) })
        }}
        onUpdate={(update) => {
            if (update.selectionSet) {
                let ranges = update.state.selection.ranges.filter(v => { return v.from != v.to })
                setExistsSelection(ranges.length > 0)
            }
        }}
        onChange={(value) => {
            setText(value)
        }}
        theme={oneDark}
        extensions={[
            keymap.of([
                {
                    key: "Shift-Enter", run: () => {
                        setNeedTypecheck(true)
                        return true
                    }
                }
            ]),
            scrollPastEnd(),
            centerCursor(editorHeight),
            
            // dynamic parts of the theme
            EditorView.theme({
                "& .cm-scroller": {
                    maxHeight: `${editorHeight}px !important`
                },
                "& .cm-activeLine": {
                    backgroundColor: `${existsSelection ? "transparent" : color.activeLine} !important`
                },
            }),
        ]}
    />;
}