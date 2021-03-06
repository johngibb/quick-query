QuickQueryConnectView = require './quick-query-connect-view'
QuickQueryResultView = require './quick-query-result-view'
QuickQueryBrowserView = require './quick-query-browser-view'
QuickQueryEditorView = require './quick-query-editor-view'
QuickQueryTableFinderView = require './quick-query-table-finder-view'
QuickQueryMysqlConnection = require './quick-query-mysql-connection'
QuickQueryPostgresConnection = require './quick-query-postgres-connection'
QuickQueryAutocomplete = require './quick-query-autocomplete'

{CompositeDisposable} = require 'atom'

module.exports = QuickQuery =
  config:
    autompleteIntegration:
      type: 'boolean'
      default: true
      title: 'Autocomplete integration'
    canUseStatusBar:
      type: 'boolean'
      default: true
      title: 'Show info in status bar'
    resultsInTab:
      type: 'boolean'
      default: false
      title: 'Show results in a tab'

  editorView: null
  browser: null
  modalPanel: null
  modalConnect: null
  modalSpinner: null
  bottomPanel: null
  sidePanel: null
  subscriptions: null
  connection: null
  connections: null
  queryEditors: []
  tableFinder: null

  activate: (state) ->
    protocols =
      mysql:
        name: "MySql"
        handler:QuickQueryMysqlConnection
      postgres:
        name: "PostgreSQL"
        handler: QuickQueryPostgresConnection
      "ssl-postgres":
        name: "PostgreSQL (ssl)"
        handler: QuickQueryPostgresConnection
        default:
          protocol: 'postgres'
          ssl: true

    @connections = []

    @tableFinder = new QuickQueryTableFinderView()

    @browser = new QuickQueryBrowserView()

    @connectView = new QuickQueryConnectView(protocols)
    @modalConnect = atom.workspace.addModalPanel(item: @connectView , visible: false)

    @modalSpinner = atom.workspace.addModalPanel(item: @createSpinner() , visible: false)

    if state.connections
      for connectionInfo in state.connections
        connectionPromise = @connectView.buildConnection(connectionInfo)
        @browser.addConnection(connectionPromise)

    @browser.onConnectionSelected (connection) =>
      @connection = connection

    @browser.onConnectionDeleted (connection) =>
      i = @connections.indexOf(connection)
      @connections.splice(i,1)
      connection.close()
      if @connections.length > 0
        @browser.selectConnection(@connections[@connections.length-1])
      else
        @connection = null

    @browser.bind 'quickQuery.edit', (e,action,model) =>
      @editorView = new QuickQueryEditorView(action,model)
      if action == 'drop'
        @editorView.openTextEditor()
      else
        @modalPanel.destroy() if @modalPanel?
        @modalPanel = atom.workspace.addModalPanel(item: @editorView , visible: true)
        @editorView.focusFirst()

    @tableFinder.onCanceled => @modalPanel.destroy()
    @tableFinder.onFound (table) =>
      @modalPanel.destroy()
      @browser.reveal table, =>
        @browser.simpleSelect()

    @connectView.onConnectionStablished (connection)=>
      @connections.push(connection)
      connection.sentenceReady (text) =>
        @addSentence(text)

    @connectView.onWillConnect (connectionPromise) =>
      @browser.addConnection(connectionPromise)
      connectionPromise.then(
        (connection) => @modalConnect.hide()
        (err) => @setModalPanel content: err, type: 'error'
      )

    # Events subscribed to in atom's system can be easily cleaned up with a CompositeDisposable
    @subscriptions = new CompositeDisposable

    # Register command that toggles this view
    @subscriptions.add atom.commands.add 'atom-workspace',
      'quick-query:run': => @run()
      'quick-query:new-editor': => @newEditor()
      'quick-query:toggle-browser': => @toggleBrowser()
      'quick-query:toggle-results': => @toggleResults()
      'core:cancel': => @cancel()
      'quick-query:new-connection': => @newConnection()
      'quick-query:find-table-to-select': => @findTable()

    atom.commands.add '.quick-query-result',
     'quick-query:copy': => @activeResultView().copy()
     'quick-query:copy-all': => @activeResultView().copyAll()
     'quick-query:save-csv': => @activeResultView().saveCSV()
     'quick-query:insert': => @activeResultView().insertRecord()
     'quick-query:null': => @activeResultView().setNull()
     'quick-query:undo': => @activeResultView().undo()
     'quick-query:delete': => @activeResultView().deleteRecord()
     'quick-query:apply': => @activeResultView().apply()

    @subscriptions.add atom.workspace.addOpener (uri) =>
      return @browser if (uri == 'quick-query://browser')

    atom.config.onDidChange 'quick-query.resultsInTab', ({newValue, oldValue}) =>
      if newValue
        for i in @queryEditors
          i.panel.hide()
          i.panel.destroy()
        @queryEditors = []
      else
        pane = atom.workspace.getActivePane()
        for item in pane.getItems()
          pane.destroyItem(item) if item instanceof QuickQueryResultView

    atom.workspace.getCenter().onDidChangeActivePaneItem (item) =>
      @hideStatusBar()
      if !atom.config.get('quick-query.resultsInTab')
        for i in @queryEditors
          resultView = i.panel.getItem()
          if i.editor == item && !resultView.hiddenResults()
            i.panel.show()
            resultView.fixNumbers()
          else
            i.panel.hide()
          @updateStatusBar(resultView) if i.editor == item
      else if item instanceof QuickQueryResultView
        @updateStatusBar(item)

    atom.workspace.getCenter().onDidDestroyPaneItem (d) =>
      @queryEditors = @queryEditors.filter (i) =>
        i.panel.destroy() if i.editor == d.item
        i.editor != d.item

  addSentence: (text) ->
    queryEditor = atom.workspace.getCenter().getActiveTextEditor()
    if queryEditor
      queryEditor.moveToBottom()
      queryEditor.insertNewline()
      queryEditor.insertText(text)
    else
      atom.workspace.open().then (editor) =>
        grammars = atom.grammars.getGrammars()
        grammar = (i for i in grammars when i.name is 'SQL')[0]
        editor.setGrammar(grammar)
        editor.insertText(text)

  deactivate: ->
    c.close() for c in @connections
    @subscriptions.dispose()
    i.panel.destroy() for i in @queryEditors
    @browser.destroy()
    @connectView.destroy()
    @modalPanel?.destroy()
    @modalConnect.destroy()
    @modalSpinner.destroy()
    @statusBarTile?.destroy()
    pane = atom.workspace.getActivePane()
    for item in pane.getItems() when item instanceof QuickQueryResultView
      pane.destroyItem(item)

  serialize: ->
     connections: @connections.map((c)-> c.serialize()),
  newEditor: ->
    atom.workspace.open().then (editor) =>
      grammars = atom.grammars.getGrammars()
      grammar = (i for i in grammars when i.name is 'SQL')[0]
      editor.setGrammar(grammar)
  newConnection: ->
    @modalConnect.show()
    @connectView.focusFirst()
  run: ->
    @queryEditor = atom.workspace.getCenter().getActiveTextEditor()
    unless @queryEditor
      @setModalPanel content:"This tab is not an editor", type:'error'
      return
    text = @queryEditor.getSelectedText()
    text = @queryEditor.getText() if(text == '')

    if @connection
      @showModalSpinner content:"Running query..."
      @connection.query text, (message, rows, fields) =>
        if (message)
          @modalSpinner.hide()
          if message.type == 'error'
            @setModalPanel message
          else
            @addInfoNotification(message.content);
          if message.type == 'success'
            @afterExecute(@queryEditor)
        else
          @showModalSpinner content:"Loading results..."
          if atom.config.get('quick-query.resultsInTab')
            queryResult = @showResultInTab()
          else
            queryResult = @showResultView(@queryEditor)
          queryResult.showRows rows, fields, @connection , =>
            @modalSpinner.hide()
            queryResult.fixSizes() if rows.length > 100
          queryResult.fixSizes()
          @updateStatusBar(queryResult)

    else
      @addWarningNotification("No connection selected")

  toggleBrowser: ->
    atom.workspace.toggle('quick-query://browser')

  findTable: ()->
    if @connection
      @tableFinder.searchTable(@connection)
      @modalPanel.destroy() if @modalPanel?
      @modalPanel = atom.workspace.addModalPanel(item: @tableFinder , visible: true)
      @tableFinder.focusFilterEditor()
    else
      @addWarningNotification "No connection selected"

  addWarningNotification:(message) ->
    notification = atom.notifications.addWarning(message);
    view = atom.views.getView(notification)
    view?.element.addEventListener 'click', (e) -> view.removeNotification()

  addInfoNotification: (message)->
    notification = atom.notifications.addInfo(message);
    view = atom.views.getView(notification)
    view?.element.addEventListener 'click', (e) -> view.removeNotification()

  setModalPanel: (message)->
    item = document.createElement('div')
    item.classList.add('quick-query-modal-message')
    content = document.createElement('span')
    content.classList.add('message')
    content.textContent = message.content
    item.appendChild(content)
    if message.type == 'error'
      item.classList.add('text-error')
      copy = document.createElement('span')
      copy.classList.add('icon','icon-clippy')
      copy.setAttribute('title',"Copy to clipboard")
      copy.setAttribute('data-error',message.content)
      item.onmouseover = (-> @classList.add('animated') )
      copy.onclick = (->atom.clipboard.write(@getAttribute('data-error')))
      item.appendChild(copy)
    close = document.createElement('span')
    close.classList.add('icon','icon-x')
    close.onclick = (=> @modalPanel.destroy())
    item.appendChild(close)
    @modalPanel.destroy() if @modalPanel?
    @modalPanel = atom.workspace.addModalPanel(item: item , visible: true)

  createSpinner: ->
    item = document.createElement('div')
    item.classList.add('quick-query-modal-spinner')
    spinner = document.createElement('span')
    spinner.classList.add('loading','loading-spinner-tiny','inline-block')
    item.appendChild spinner
    content = document.createElement('span')
    content.classList.add('message')
    item.appendChild content
    return item

  showModalSpinner: (message)->
    item = @modalSpinner.getItem()
    content = item.getElementsByClassName('message').item(0)
    content.textContent = message.content
    @modalSpinner.show()

  showResultInTab: ->
    pane = atom.workspace.getCenter().getActivePane()
    filter = pane.getItems().filter (item) ->
      item instanceof QuickQueryResultView
    if filter.length == 0
      queryResult = new QuickQueryResultView()
      queryResult.onRowStatusChanged => @updateStatusBar(queryResult)
      pane.addItem queryResult
    else
      queryResult = filter[0]
    pane.activateItem queryResult
    queryResult

  afterExecute: (queryEditor)->
    if @editorView && @editorView.editor == queryEditor
      if !queryEditor.getPath?()
        queryEditor.setText('')
        queryEditor.destroy()
      @browser.refreshTree(@editorView.model)
      @modalPanel.destroy() if @modalPanel
      @editorView = null

  showResultView: (queryEditor)->
    e = (i for i in @queryEditors when i.editor == queryEditor)
    if e.length > 0
      e[0].panel.show()
      queryResult = e[0].panel.getItem()
    else
      queryResult = new QuickQueryResultView()
      queryResult.onRowStatusChanged => @updateStatusBar(queryResult)
      bottomPanel = atom.workspace.addBottomPanel(item: queryResult, visible:true )
      @queryEditors.push({editor: queryEditor,  panel: bottomPanel})
    queryResult

  activeResultView: ->
    if atom.config.get('quick-query.resultsInTab')
      atom.workspace.getActivePaneItem()
    else
      editor = atom.workspace.getCenter().getActiveTextEditor()
      for i in @queryEditors
        return i.panel.getItem() if i.editor == editor

  provideBrowserView: -> @browser

  provideConnectView: -> @connectView

  provideAutocomplete: -> new QuickQueryAutocomplete(@browser)

  consumeStatusBar: (statusBar) ->
    element = document.createElement('a')
    element.classList.add('quick-query-tile')
    element.classList.add('hide')
    element.onclick = (=> @toggleResults())
    @statusBarTile = statusBar.addLeftTile(item: element, priority: 10)

  hideStatusBar: ->
    if @statusBarTile?
      span = @statusBarTile.getItem()
      span.classList.add('hide')

  updateStatusBar: (queryResult) ->
    return unless @statusBarTile? && queryResult?.rows?
    return unless atom.config.get('quick-query.canUseStatusBar')
    element = @statusBarTile.getItem()
    element.classList.remove('hide')
    if atom.config.get('quick-query.resultsInTab')
      element.textContent = "(#{queryResult.rowsStatus()})"
    else
      element.textContent = "#{queryResult.getTitle()} (#{queryResult.rowsStatus()})"

  toggleResults: ->
    if !atom.config.get('quick-query.resultsInTab')
      editor = atom.workspace.getCenter().getActiveTextEditor()
      for i in @queryEditors when i.editor == editor
        resultView = i.panel.getItem()
        if resultView.is(':visible')
         i.panel.hide()
         resultView.hideResults()
        else
         i.panel.show()
         resultView.showResults()

  cancel: ->
    @modalPanel.destroy() if @modalPanel
    @modalConnect.hide()
    if @modalSpinner.isVisible()
      resultView = @activeResultView()
      if resultView?
        resultView.stopLoop()
        @updateStatusBar(resultView)
      @modalSpinner.hide()
    for i in @queryEditors
      if i.editor == atom.workspace.getCenter().getActiveTextEditor()
        resultView = i.panel.getItem()
        i.panel.hide()
        resultView.hideResults()
