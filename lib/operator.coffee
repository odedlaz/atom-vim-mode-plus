LineEndingRegExp = /(?:\n|\r\n)$/

_ = require 'underscore-plus'
{Point, Range, CompositeDisposable, BufferedProcess} = require 'atom'

{
  haveSomeSelection, getVimEofBufferPosition
  moveCursorLeft, moveCursorRight
  highlightRanges, getNewTextRangeFromCheckpoint
  preserveSelectionStartPoints
  isEndsWithNewLineForBufferRow
} = require './utils'
swrap = require './selection-wrapper'
settings = require './settings'
Base = require './base'

# -------------------------
class OperatorError extends Base
  @extend(false)
  constructor: (@message) ->
    @name = 'Operator Error'

# -------------------------
class Operator extends Base
  @extend(false)
  recordable: true
  flashTarget: true
  trackChange: false
  requireTarget: true
  finalMode: "normal"
  finalSubmode: null

  setMarkForChange: ({start, end}) ->
    @vimState.mark.set('[', start)
    @vimState.mark.set(']', end)

  needFlash: ->
    if @flashTarget and settings.get('flashOnOperate')
      @getName() not in settings.get('flashOnOperateBlacklist')
    else
      false

  needTrackChange: ->
    @trackChange

  # [FIXME]
  # For TextObject, isLinewise result is changed before / after select.
  # This mean return value may change depending on when you call.
  needStay: ->
    param = if @instanceof('TransformString')
      "stayOnTransformString"
    else
      "stayOn#{@getName()}"
    settings.get(param) or (@stayOnLinewise and @target.isLinewise?())

  constructor: ->
    super
    # Guard when Repeated.
    return if @instanceof("Repeat")

    # [important] intialized is not called when Repeated
    @initialize?()
    @setTarget @new(@target) if _.isString(@target)

  markSelectedBufferRange: ->
    @editor.markBufferRange @editor.getSelectedBufferRange(),
      invalidate: 'never'
      persistent: false

  restorePoint: (selection) ->
    # [FIXME] WIP: set to 'head' on needStay
    swrap(selection).setBufferPositionFromProperty('start')

  observeSelectAction: ->
    unless @instanceof('Select')
      if @needStay() # [FIXME] WIP
        # unless @isMode('visual')
        @onWillSelectTarget => swrap.preserveCharacterwise(@editor)
      else
        @onDidSelectTarget => swrap.preserveCharacterwise(@editor)

    if @needFlash()
      @onDidSelectTarget =>
        @flash(@editor.getSelectedBufferRanges())

    if @needTrackChange()
      marker = null
      @onDidSelectTarget =>
        marker = @markSelectedBufferRange()

      @onDidFinishOperation =>
        @setMarkForChange(range) if (range = marker.getBufferRange())

  # @target - TextObject or Motion to operate on.
  setTarget: (@target) ->
    unless _.isFunction(@target.select)
      @vimState.emitter.emit('did-fail-to-set-target')
      throw new OperatorError("#{@getName()} cannot set #{@target.getName()} as target")
    @target.setOperator(this)
    @emitDidSetTarget(this)
    this

  # Return true unless all selection is empty.
  # -------------------------
  selectTarget: ->
    @observeSelectAction()
    @emitWillSelectTarget()
    @target.select()
    @emitDidSelectTarget()
    haveSomeSelection(@editor)

  setTextToRegisterForSelection: (selection) ->
    @setTextToRegister(selection.getText(), selection)

  setTextToRegister: (text, selection) ->
    if @target.isLinewise?() and not text.endsWith('\n')
      text += "\n"
    if text
      @vimState.register.set({text, selection})

  flash: (ranges) ->
    highlightRanges @editor, ranges,
      class: 'vim-mode-plus-flash'
      timeout: settings.get('flashOnOperateDuration')

  mutateSelections: (fn) ->
    if @selectTarget()
      @editor.transact =>
        fn(selection) for selection in @editor.getSelections()

  execute: ->
    # We need to preserve selection before selection is cleared as a result of mutation.
    if @isMode('visual')
      lastSelection = if @isMode('visual', 'blockwise')
        @vimState.getLastBlockwiseSelection()
      else
        @editor.getLastSelection()
      @vimState.modeManager.preservePreviousSelection(lastSelection)

    @mutateSelections (selection) =>
      @mutateSelection(selection)
    @activateMode(@finalMode, @finalSubmode)

# -------------------------
class Select extends Operator
  @extend(false)
  flashTarget: false
  recordable: false
  execute: ->
    @selectTarget()
    return if @isMode('operator-pending') or @isMode('visual', 'blockwise')
    if not @isMode('visual')
      submode = swrap.detectVisualModeSubmode(@editor)
      @activateMode('visual', submode)
    else
      if @target.isAllowSubmodeChange?()
        submode = swrap.detectVisualModeSubmode(@editor)
        if submode? and not @isMode('visual', submode)
          @activateMode('visual', submode)

class SelectLatestChange extends Select
  @extend()
  @description: "Select latest yanked or changed range"
  target: 'ALatestChange'

# -------------------------
class Delete extends Operator
  @extend()
  hover: icon: ':delete:', emoji: ':scissors:'
  trackChange: true
  flashTarget: false

  mutateSelection: (selection) =>
    {cursor} = selection
    wasLinewise = swrap(selection).isLinewise()
    @setTextToRegisterForSelection(selection)
    selection.deleteSelectedText()

    vimEof = getVimEofBufferPosition(@editor)
    if cursor.getBufferPosition().isGreaterThan(vimEof)
      cursor.setBufferPosition([vimEof.row, 0])
    cursor.skipLeadingWhitespace() if wasLinewise

class DeleteRight extends Delete
  @extend()
  target: 'MoveRight'

class DeleteLeft extends Delete
  @extend()
  target: 'MoveLeft'

class DeleteToLastCharacterOfLine extends Delete
  @extend()
  target: 'MoveToLastCharacterOfLine'
  initialize: ->
    if @isVisualBlockwise = @isMode('visual', 'blockwise')
      @requireTarget = false

  execute: ->
    if @isVisualBlockwise
      pointByBlockwiseSelection = new Map
      @getBlockwiseSelections().forEach (bs) ->
        bs.removeEmptySelections()
        bs.setPositionForSelections('start')
        pointByBlockwiseSelection.set(bs, bs.getTop().getHeadBufferPosition())

    super

    if @isVisualBlockwise
      pointByBlockwiseSelection.forEach (point, bs) ->
        bs.setHeadBufferPosition(point)

# -------------------------
class TransformString extends Operator
  @extend(false)
  trackChange: true
  stayOnLinewise: true
  setPoint: true
  autoIndent: false

  mutateSelection: (selection) ->
    text = @getNewText(selection.getText(), selection)
    selection.insertText(text, {@autoIndent})
    @restorePoint(selection) if @setPoint

# String Transformer
# -------------------------
class ToggleCase extends TransformString
  @extend()
  displayName: 'Toggle ~'
  hover: icon: ':toggle-case:', emoji: ':clap:'
  toggleCase: (char) ->
    charLower = char.toLowerCase()
    if charLower is char
      char.toUpperCase()
    else
      charLower

  getNewText: (text) ->
    text.split('').map(@toggleCase).join('')

class ToggleCaseAndMoveRight extends ToggleCase
  @extend()
  hover: null
  setPoint: false
  target: 'MoveRight'

class UpperCase extends TransformString
  @extend()
  displayName: 'Upper'
  hover: icon: ':upper-case:', emoji: ':point_up:'
  getNewText: (text) ->
    text.toUpperCase()

class LowerCase extends TransformString
  @extend()
  displayName: 'Lower'
  hover: icon: ':lower-case:', emoji: ':point_down:'
  getNewText: (text) ->
    text.toLowerCase()

class CamelCase extends TransformString
  @extend()
  displayName: 'Camelize'
  hover: icon: ':camel-case:', emoji: ':camel:'
  getNewText: (text) ->
    _.camelize(text)

class SnakeCase extends TransformString
  @extend()
  @description: "CamelCase -> camel_case"
  displayName: 'Underscore _'
  hover: icon: ':snake-case:', emoji: ':snake:'
  getNewText: (text) ->
    _.underscore(text)

class DashCase extends TransformString
  @extend()
  displayName: 'Dasherize -'
  hover: icon: ':dash-case:', emoji: ':dash:'
  getNewText: (text) ->
    _.dasherize(text)

class TitleCase extends TransformString
  @extend()
  @description: "CamelCase -> Camel Case"
  displayName: 'Titlize'
  getNewText: (text) ->
    _.humanizeEventName(_.dasherize(text))

class EncodeUriComponent extends TransformString
  @extend()
  @description: "URI encode string"
  displayName: 'Encode URI Component %'
  hover: icon: 'encodeURI', emoji: 'encodeURI'
  getNewText: (text) ->
    encodeURIComponent(text)

class DecodeUriComponent extends TransformString
  @extend()
  @description: "Decode URL encoded string"
  displayName: 'Decode URI Component %%'
  hover: icon: 'decodeURI', emoji: 'decodeURI'
  getNewText: (text) ->
    decodeURIComponent(text)

# -------------------------
class TransformStringByExternalCommand extends TransformString
  @extend(false)
  autoIndent: true
  command: '' # e.g. command: 'sort'
  args: [] # e.g args: ['-rn']
  stdoutBySelection: null

  execute: ->
    new Promise (resolve) =>
      @collect(resolve)
    .then =>
      super

  collect: (resolve) ->
    @stdoutBySelection = new Map
    restorePoint = null
    unless @isMode('visual')
      # swrap(selection).preserveCharacterwise() for selection in @editor.getSelections()

      restorePoint = preserveSelectionStartPoints(@editor)
      @target.select()

    running = finished = 0
    for selection in @editor.getSelections()
      running++
      {command, args} = @getCommand(selection) ? {}
      if command? and args?
        do (selection) =>
          stdin = @getStdin(selection)
          stdout = (output) =>
            @stdoutBySelection.set(selection, output)
          exit = (code) ->
            finished++
            resolve() if (running is finished)

          @runExternalCommand {command, args, stdout, exit, stdin}
          restorePoint?(selection)

  runExternalCommand: (options) ->
    {stdin} = options
    delete options.stdin
    bufferedProcess = new BufferedProcess(options)
    bufferedProcess.onWillThrowError ({error, handle}) =>
      # Suppress command not found error intentionally.
      if error.code is 'ENOENT' and error.syscall.indexOf('spawn') is 0
        commandName = @constructor.getCommandName()
        console.log "#{commandName}: Failed to spawn command #{error.path}."
      @cancelOperation()
      handle()

    if stdin
      bufferedProcess.process.stdin.write(stdin)
      bufferedProcess.process.stdin.end()

  getNewText: (text, selection) ->
    @getStdout(selection) ? text

  # For easily extend by vmp plugin.
  getCommand: (selection) ->
    {@command, @args}

  # For easily extend by vmp plugin.
  getStdin: (selection) ->
    selection.getText()

  # For easily extend by vmp plugin.
  getStdout: (selection) ->
    @stdoutBySelection.get(selection)

# -------------------------
class TransformStringBySelectList extends Operator
  @extend()
  @description: "Transform string by specified oprator selected from select-list"
  requireInput: true
  # Member of transformers can be either of
  # - Operation class name: e.g 'CamelCase'
  # - Operation class itself: e.g. CamelCase
  transformers: [
    'CamelCase'
    'DashCase'
    'SnakeCase'
    'TitleCase'
    'EncodeUriComponent'
    'DecodeUriComponent'
    'Reverse'
    'Surround'
    'MapSurround'
    'IncrementNumber'
    'DecrementNumber'
    'JoinByInput'
    'JoinWithKeepingSpace'
    'SplitString'
    'LowerCase'
    'UpperCase'
    'ToggleCase'
  ]

  getItems: ->
    @transformers.map (klass) ->
      klass = Base.getClass(klass) if _.isString(klass)
      displayName = klass::displayName if klass::hasOwnProperty('displayName')
      displayName ?= _.humanizeEventName(_.dasherize(klass.name))
      {name: klass, displayName}

  initialize: ->
    @onDidSetTarget =>
      @focusSelectList({items: @getItems()})

    @vimState.onDidConfirmSelectList (transformer) =>
      @vimState.reset()
      @vimState.operationStack.run(transformer.name, {target: @target.constructor.name})

  execute: ->
    # NEVER be executed since operationStack is replaced with selected transformer

class TransformWordBySelectList extends TransformStringBySelectList
  @extend()
  target: "InnerWord"

class TransformSmartWordBySelectList extends TransformStringBySelectList
  @extend()
  @description: "Transform InnerSmartWord by `transform-string-by-select-list`"
  target: "InnerSmartWord"

# -------------------------
class ReplaceWithRegister extends TransformString
  @extend()
  @description: "Replace target with specified register value"
  hover: icon: ':replace-with-register:', emoji: ':pencil:'
  getNewText: (text) ->
    @vimState.register.getText()

# Save text to register before replace
class SwapWithRegister extends TransformString
  @extend()
  @description: "Swap register value with target"
  getNewText: (text, selection) ->
    newText = @vimState.register.getText()
    @setTextToRegister(text, selection)
    newText

# -------------------------
class Indent extends TransformString
  @extend()
  hover: icon: ':indent:', emoji: ':point_right:'
  stayOnLinewise: false

  mutateSelection: (selection) ->
    @indent(selection)
    @restorePoint(selection)
    unless @needStay()
      selection.cursor.moveToFirstCharacterOfLine()

  indent: (selection) ->
    selection.indentSelectedRows()

class Outdent extends Indent
  @extend()
  hover: icon: ':outdent:', emoji: ':point_left:'
  indent: (selection) ->
    selection.outdentSelectedRows()

class AutoIndent extends Indent
  @extend()
  hover: icon: ':auto-indent:', emoji: ':open_hands:'
  indent: (selection) ->
    selection.autoIndentSelectedRows()

# -------------------------
class ToggleLineComments extends TransformString
  @extend()
  hover: icon: ':toggle-line-comments:', emoji: ':mute:'
  mutateSelection: (selection) ->
    selection.toggleLineComments()
    @restorePoint(selection)

# -------------------------
class Surround extends TransformString
  @extend()
  @description: "Surround target by specified character like `(`, `[`, `\"`"
  displayName: "Surround ()"
  pairs: [
    ['[', ']']
    ['(', ')']
    ['{', '}']
    ['<', '>']
  ]
  input: null
  charsMax: 1
  hover: icon: ':surround:', emoji: ':two_women_holding_hands:'
  requireInput: true
  autoIndent: false

  initialize: ->
    return unless @requireInput
    @onDidConfirmInput (input) => @onConfirm(input)
    @onDidChangeInput (input) => @addHover(input)
    @onDidCancelInput => @cancelOperation()
    if @requireTarget
      @onDidSetTarget =>
        @vimState.input.focus({@charsMax})
    else
      @vimState.input.focus({@charsMax})

  onConfirm: (@input) ->
    @processOperation()

  getPair: (input) ->
    pair = _.detect @pairs, (pair) -> input in pair
    pair ?= [input, input]

  surround: (text, pair) ->
    [open, close] = pair
    if LineEndingRegExp.test(text)
      @autoIndent = true # [FIXME]
      open += "\n"
      close += "\n"

    SpaceSurroundedRegExp = /^\s([\s|\S]+)\s$/
    isSurroundedBySpace = (text) ->
      SpaceSurroundedRegExp.test(text)

    if @input in settings.get('charactersToAddSpaceOnSurround') and not isSurroundedBySpace(text)
      open + ' ' + text + ' ' + close
    else
      open + text + close

  getNewText: (text) ->
    @surround text, @getPair(@input)

class SurroundWord extends Surround
  @extend()
  @description: "Surround **word**"
  target: 'InnerWord'

class SurroundSmartWord extends Surround
  @extend()
  @description: "Surround **smart-word**"
  target: 'InnerSmartWord'

class MapSurround extends Surround
  @extend()
  @description: "Surround each word(`/\w+/`) within target"
  mapRegExp: /\w+/g

  mutateSelection: (selection) ->
    scanRange = selection.getBufferRange()
    @editor.scanInBufferRange @mapRegExp, scanRange, ({matchText, replace}) =>
      replace(@getNewText(matchText))
    @restorePoint(selection) if @setPoint

class DeleteSurround extends Surround
  @extend()
  @description: "Delete specified surround character like `(`, `[`, `\"`"
  pairChars: ['[]', '()', '{}'].join('')
  requireTarget: false

  onConfirm: (@input) ->
    # FIXME: dont manage allowNextLine independently. Each Pair text-object can handle by themselvs.
    @setTarget @new 'Pair',
      pair: @getPair(@input)
      inner: false
      allowNextLine: (@input in @pairChars)
    @processOperation()

  getNewText: (text) ->
    isSingleLine = (text) ->
      text.split(/\n|\r\n/).length is 1
    text = text[1...-1]
    if isSingleLine(text)
      text.trim()
    else
      text

class DeleteSurroundAnyPair extends DeleteSurround
  @extend()
  @description: "Delete surround character by auto-detect paired char from cursor enclosed pair"
  requireInput: false
  target: 'AAnyPair'

class DeleteSurroundAnyPairAllowForwarding extends DeleteSurroundAnyPair
  @extend()
  @description: "Delete surround character by auto-detect paired char from cursor enclosed pair and forwarding pair within same line"
  target: 'AAnyPairAllowForwarding'

class ChangeSurround extends DeleteSurround
  @extend()
  @description: "Change surround character, specify both from and to pair char"
  charsMax: 2
  char: null

  onConfirm: (input) ->
    return unless input
    [from, @char] = input.split('')
    super(from)

  getNewText: (text) ->
    [open, close] = @getPair(@char)
    open + text[1...-1] + close

class ChangeSurroundAnyPair extends ChangeSurround
  @extend()
  @description: "Change surround character, from char is auto-detected"
  charsMax: 1
  target: "AAnyPair"

  initialize: ->
    @onDidSetTarget =>
      @restore = preserveSelectionStartPoints(@editor)
      @target.select()
      unless haveSomeSelection(@editor)
        @vimState.reset()
        @abort()
      @addHover(@editor.getSelectedText()[0])
    super

  onConfirm: (@char) ->
    # Clear pre-selected selection to start mutation non-selection.
    @restore(selection) for selection in @editor.getSelections()
    @input = @char
    @processOperation()

class ChangeSurroundAnyPairAllowForwarding extends ChangeSurroundAnyPair
  @extend()
  @description: "Change surround character, from char is auto-detected from enclosed and forwarding area"
  target: "AAnyPairAllowForwarding"

# -------------------------
class Yank extends Operator
  @extend()
  hover: icon: ':yank:', emoji: ':clipboard:'
  trackChange: true
  stayOnLinewise: true

  mutateSelection: (selection) ->
    @setTextToRegisterForSelection(selection)
    @restorePoint(selection)

class YankLine extends Yank
  @extend()
  target: 'MoveToRelativeLine'

# -------------------------
# FIXME
# Currently native editor.joinLines() is better for cursor position setting
# So I use native methods for a meanwhile.
class Join extends Operator
  @extend()
  requireTarget: false
  execute: ->
    @editor.transact =>
      @countTimes =>
        @editor.joinLines()
    @activateMode('normal')

class JoinWithKeepingSpace extends TransformString
  @extend()
  input: ''
  requireTarget: false
  trim: false
  initialize: ->
    @setTarget @new("MoveToRelativeLineWithMinimum", {min: 1})

  mutateSelection: (selection) ->
    [startRow, endRow] = selection.getBufferRowRange()
    swrap(selection).expandOverLine()
    rows = for row in [startRow..endRow]
      text = @editor.lineTextForBufferRow(row)
      if @trim and row isnt startRow
        text.trimLeft()
      else
        text
    selection.insertText @join(rows) + "\n"

  join: (rows) ->
    rows.join(@input)

class JoinByInput extends JoinWithKeepingSpace
  @extend()
  @description: "Transform multi-line to single-line by with specified separator character"
  hover: icon: ':join:', emoji: ':couple:'
  requireInput: true
  input: null
  trim: true
  initialize: ->
    super
    @focusInput(charsMax: 10)

  join: (rows) ->
    rows.join(" #{@input} ")

class JoinByInputWithKeepingSpace extends JoinByInput
  @description: "Join lines without padding space between each line"
  @extend()
  trim: false
  join: (rows) ->
    rows.join(@input)

# -------------------------
# String suffix in name is to avoid confusion with 'split' window.
class SplitString extends TransformString
  @extend()
  @description: "Split single-line into multi-line by splitting specified separator chars"
  hover: icon: ':split-string:', emoji: ':hocho:'
  requireInput: true
  input: null

  initialize: ->
    unless @isMode('visual')
      @setTarget @new("MoveToRelativeLine", {min: 1})
    @focusInput(charsMax: 10)

  getNewText: (text) ->
    @input = "\\n" if @input is ''
    regex = ///#{_.escapeRegExp(@input)}///g
    text.split(regex).join("\n")

class Reverse extends TransformString
  @extend()
  @description: "Reverse lines(e.g reverse selected three line)"
  mutateSelection: (selection) ->
    swrap(selection).expandOverLine()
    textForRows = swrap(selection).lineTextForBufferRows()
    newText = textForRows.reverse().join("\n") + "\n"
    selection.insertText(newText)
    @restorePoint(selection)

# -------------------------
class Repeat extends Operator
  @extend()
  requireTarget: false
  recordable: false

  execute: ->
    @editor.transact =>
      @countTimes =>
        if operation = @vimState.operationStack.getRecorded()
          operation.setRepeated()
          operation.execute()

# -------------------------
class Mark extends Operator
  @extend()
  hover: icon: ':mark:', emoji: ':round_pushpin:'
  requireInput: true
  requireTarget: false
  initialize: ->
    @focusInput()

  execute: ->
    @vimState.mark.set(@input, @editor.getCursorBufferPosition())
    @activateMode('normal')

# -------------------------
# [FIXME?]: inconsistent behavior from normal operator
# Since its support visual-mode but not use setTarget() convension.
# Maybe separating complete/in-complete version like IncreaseNow and Increase?
class Increase extends Operator
  @extend()
  requireTarget: false
  step: 1

  execute: ->
    pattern = ///#{settings.get('numberRegex')}///g

    newRanges = []
    @editor.transact =>
      for cursor in @editor.getCursors()
        scanRange = if @isMode('visual')
          cursor.selection.getBufferRange()
        else
          cursor.getCurrentLineBufferRange()
        ranges = @increaseNumber(cursor, scanRange, pattern)
        if not @isMode('visual') and ranges.length
          cursor.setBufferPosition ranges[0].end.translate([0, -1])
        newRanges.push ranges

    if (newRanges = _.flatten(newRanges)).length
      @flash(newRanges) if @needFlash()
    else
      atom.beep()

  increaseNumber: (cursor, scanRange, pattern) ->
    newRanges = []
    @editor.scanInBufferRange pattern, scanRange, ({matchText, range, stop, replace}) =>
      newText = String(parseInt(matchText, 10) + @step * @getCount())
      if @isMode('visual')
        newRanges.push replace(newText)
      else
        return unless range.end.isGreaterThan cursor.getBufferPosition()
        newRanges.push replace(newText)
        stop()
    newRanges

class Decrease extends Increase
  @extend()
  step: -1

# -------------------------
class IncrementNumber extends Operator
  @extend()
  displayName: 'Increment ++'
  step: 1
  baseNumber: null

  execute: ->
    pattern = ///#{settings.get('numberRegex')}///g
    newRanges = null
    @selectTarget()
    @editor.transact =>
      newRanges = for selection in @editor.getSelectionsOrderedByBufferPosition()
        @replaceNumber(selection.getBufferRange(), pattern)
    if (newRanges = _.flatten(newRanges)).length
      @flash(newRanges) if @needFlash()
    else
      atom.beep()
    for selection in @editor.getSelections()
      selection.cursor.setBufferPosition(selection.getBufferRange().start)
    @activateMode('normal')

  replaceNumber: (scanRange, pattern) ->
    newRanges = []
    @editor.scanInBufferRange pattern, scanRange, ({matchText, replace}) =>
      newRanges.push replace(@getNewText(matchText))
    newRanges

  getNewText: (text) ->
    @baseNumber = if @baseNumber?
      @baseNumber + @step * @getCount()
    else
      parseInt(text, 10)
    String(@baseNumber)

class DecrementNumber extends IncrementNumber
  @extend()
  displayName: 'Decrement --'
  step: -1

# Put
# -------------------------
class PutBefore extends Operator
  @extend()
  requireTarget: false
  location: 'before'

  execute: ->
    @editor.transact =>
      for selection in @editor.getSelections()
        {cursor} = selection

        {text, type} = @vimState.register.get(null, selection)
        break unless text
        text = _.multiplyString(text, @getCount())
        newRange = @paste selection, text,
          linewise: (type is 'linewise') or @isMode('visual', 'linewise')
          select: @selectPastedText
        @setMarkForChange(newRange)
        @flash(newRange) if @needFlash()

    if @selectPastedText
      submode = swrap.detectVisualModeSubmode(@editor)
      unless @isMode('visual', submode)
        @activateMode('visual', submode)
    else
      @activateMode('normal')

  paste: (selection, text, {linewise, select}) ->
    {cursor} = selection
    select ?= false
    linewise ?= false
    if linewise
      newRange = @pasteLinewise(selection, text)
      adjustCursor = (range) ->
        cursor.setBufferPosition(range.start)
        cursor.moveToFirstCharacterOfLine()
    else
      newRange = @pasteCharacterwise(selection, text)
      adjustCursor = (range) ->
        cursor.setBufferPosition(range.end.translate([0, -1]))

    if select
      selection.setBufferRange(newRange)
    else
      adjustCursor(newRange)
    newRange

  # Return newRange
  pasteLinewise: (selection, text) ->
    {cursor} = selection
    text += "\n" unless text.endsWith("\n")
    if selection.isEmpty()
      row = cursor.getBufferRow()
      switch @location
        when 'before'
          range = [[row, 0], [row, 0]]
        when 'after'
          unless isEndsWithNewLineForBufferRow(@editor, row)
            text = text.replace(LineEndingRegExp, '')
          cursor.moveToEndOfLine()
          {end} = selection.insertText("\n")
          range = @editor.bufferRangeForBufferRow(end.row, {includeNewline: true})
      @editor.setTextInBufferRange(range, text)
    else
      if @isMode('visual', 'linewise')
        unless selection.getBufferRange().end.column is 0
          text = text.replace(LineEndingRegExp, '')
      else
        selection.insertText("\n")
      selection.insertText(text)

  pasteCharacterwise: (selection, text) ->
    if @location is 'after' and selection.isEmpty()
      selection.cursor.moveRight()
    selection.insertText(text)

class PutAfter extends PutBefore
  @extend()
  location: 'after'

class PutBeforeAndSelect extends PutBefore
  @extend()
  @description: "Paste before then select"
  selectPastedText: true

class PutAfterAndSelect extends PutAfter
  @extend()
  @description: "Paste after then select"
  selectPastedText: true

# Replace
# -------------------------
class Replace extends Operator
  @extend()
  input: null
  hover: icon: ':replace:', emoji: ':tractor:'
  flashTarget: false
  trackChange: true
  requireInput: true

  initialize: ->
    @setTarget(@new('MoveRight')) if @isMode('normal')
    @focusInput()

  getInput: ->
    input = super
    input = "\n" if input is ''
    input

  execute: ->
    input = @getInput()
    @mutateSelections (selection) =>
      text = selection.getText().replace(/./g, input)
      unless (@target.instanceof('MoveRight') and (text.length < @getCount()))
        selection.insertText(text, autoIndentNewline: true)
      @restorePoint(selection) unless input is "\n"

    # FIXME this is very imperative, handling in very lower level.
    # find better place for operator in blockwise move works appropriately.
    if @isMode('visual', 'blockwise')
      top = @editor.getSelectionsOrderedByBufferPosition()[0]
      for selection in @editor.getSelections() when (selection isnt top)
        selection.destroy()

    @activateMode('normal')

# Insert entering operation
# -------------------------
class ActivateInsertMode extends Operator
  @extend()
  requireTarget: false
  flashTarget: false
  checkpoint: null
  finalSubmode: null
  supportInsertionCount: true

  observeWillDeactivateMode: ->
    disposable = @vimState.modeManager.preemptWillDeactivateMode ({mode}) =>
      return unless mode is 'insert'
      disposable.dispose()

      @vimState.mark.set('^', @editor.getCursorBufferPosition())
      if (range = getNewTextRangeFromCheckpoint(@editor, @getCheckpoint('insert')))?
        @setMarkForChange(range) # Marker can track following extra insertion incase count specified
        textByUserInput = @editor.getTextInBufferRange(range)
      else
        textByUserInput = ''
      @saveInsertedText(textByUserInput)
      @vimState.register.set('.', {text: textByUserInput})

      _.times @getInsertionCount(), =>
        text = @textByOperator + textByUserInput
        for selection in @editor.getSelections()
          selection.insertText(text, autoIndent: true)

      # grouping changes for undo checkpoint need to come last
      @editor.groupChangesSinceCheckpoint(@getCheckpoint('undo'))

  initialize: ->
    @checkpoint = {}
    @setCheckpoint('undo') unless @isRepeated()
    @observeWillDeactivateMode()

  # we have to manage two separate checkpoint for different purpose(timing is different)
  # - one for undo(handled by modeManager)
  # - one for preserve last inserted text
  setCheckpoint: (purpose) ->
    @checkpoint[purpose] = @editor.createCheckpoint()

  getCheckpoint: (purpose) ->
    @checkpoint[purpose]

  saveInsertedText: (@insertedText) -> @insertedText

  getInsertedText: ->
    @insertedText ? ''

  # called when repeated
  repeatInsert: (selection, text) ->
    selection.insertText(text, autoIndent: true)

  getInsertionCount: ->
    @insertionCount ?= if @supportInsertionCount then (@getCount() - 1) else 0
    @insertionCount

  execute: ->
    if @isRepeated()
      return unless text = @getInsertedText()
      unless @instanceof('Change')
        @flashTarget = @trackChange = true
        @observeSelectAction()
        @emitDidSelectTarget()
      @editor.transact =>
        for selection in @editor.getSelections()
          @repeatInsert(selection, text)
          moveCursorLeft(selection.cursor)
    else
      if @getInsertionCount() > 0
        range = getNewTextRangeFromCheckpoint(@editor, @getCheckpoint('undo'))
        @textByOperator = if range? then @editor.getTextInBufferRange(range) else ''
      @setCheckpoint('insert')
      @vimState.activate('insert', @finalSubmode)

class InsertAtLastInsert extends ActivateInsertMode
  @extend()
  execute: ->
    if (point = @vimState.mark.get('^'))
      @editor.setCursorBufferPosition(point)
      @editor.scrollToCursorPosition({center: true})
    super

class InsertAtStartOfSelection extends ActivateInsertMode
  @extend()
  which: 'start'
  execute: ->
    if @isMode('visual', 'blockwise')
      @getBlockwiseSelections().forEach (bs) =>
        bs.removeEmptySelections()
        bs.setPositionForSelections(@which)
    super

class InsertAtEndOfSelection extends InsertAtStartOfSelection
  @extend()
  which: 'end'

class ActivateReplaceMode extends ActivateInsertMode
  @extend()
  finalSubmode: 'replace'

  repeatInsert: (selection, text) ->
    for char in text when (char isnt "\n")
      break if selection.cursor.isAtEndOfLine()
      selection.selectRight()
    selection.insertText(text, autoIndent: false)

class InsertAfter extends ActivateInsertMode
  @extend()
  execute: ->
    moveCursorRight(cursor) for cursor in @editor.getCursors()
    super

class InsertAfterEndOfLine extends ActivateInsertMode
  @extend()
  execute: ->
    @editor.moveToEndOfLine()
    super

class InsertAtBeginningOfLine extends ActivateInsertMode
  @extend()
  execute: ->
    @editor.moveToBeginningOfLine()
    @editor.moveToFirstCharacterOfLine()
    super

class InsertByMotion extends ActivateInsertMode
  @extend()
  @description: "Move by specified motion then enter insert-mode(`i`)"
  requireTarget: true
  execute: ->
    if @target.isMotion()
      @target.execute()
    if @instanceof('InsertAfterByMotion')
      moveCursorRight(cursor) for cursor in @editor.getCursors()
    super

class InsertAfterByMotion extends InsertByMotion
  @description: "Move by specified motion then enter insert-mode(`a`)"
  @extend()

class InsertAtPreviousFoldStart extends InsertByMotion
  @extend()
  @description: "Move to previous fold start then enter insert-mode"
  target: 'MoveToPreviousFoldStart'

class InsertAtNextFoldStart extends InsertAtPreviousFoldStart
  @extend()
  @description: "Move to next fold start then enter insert-mode"
  target: 'MoveToNextFoldStart'

class InsertAboveWithNewline extends ActivateInsertMode
  @extend()
  execute: ->
    @insertNewline()
    super

  insertNewline: ->
    @editor.insertNewlineAbove()

  repeatInsert: (selection, text) ->
    selection.insertText(text.trimLeft(), autoIndent: true)

class InsertBelowWithNewline extends InsertAboveWithNewline
  @extend()
  insertNewline: ->
    @editor.insertNewlineBelow()
# -------------------------
class Change extends ActivateInsertMode
  @extend()
  requireTarget: true
  trackChange: true
  supportInsertionCount: false

  execute: ->
    @selectTarget()
    text = ''
    if @target.isTextObject() or @target.isMotion()
      text = "\n" if (swrap.detectVisualModeSubmode(@editor) is 'linewise')
    else
      text = "\n" if @target.isLinewise?()

    @editor.transact =>
      for selection in @editor.getSelections()
        @setTextToRegisterForSelection(selection)
        range = selection.insertText(text, autoIndent: true)
        selection.cursor.moveLeft() unless range.isEmpty()
    super

class Substitute extends Change
  @extend()
  target: 'MoveRight'

class SubstituteLine extends Change
  @extend()
  target: 'MoveToRelativeLine'

class ChangeToLastCharacterOfLine extends Change
  @extend()
  target: 'MoveToLastCharacterOfLine'

  initialize: ->
    if @isVisualBlockwise = @isMode('visual', 'blockwise')
      @requireTarget = false
    super

  execute: ->
    if @isVisualBlockwise
      @getBlockwiseSelections().forEach (bs) ->
        bs.removeEmptySelections()
        bs.setPositionForSelections('start')
    super
