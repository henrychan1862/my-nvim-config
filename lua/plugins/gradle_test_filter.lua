local function run_gradle_test_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1
  local function declaration_name(node)
    local name = node:field("name")[1]
    if name then
      return name
    end
    for child in node:iter_children() do
      if child:type() == "simple_identifier" or child:type() == "type_identifier" then
        return child
      end
    end
  end

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "kotlin")
  if not ok then
    vim.notify("Kotlin Tree-sitter parser is required", vim.log.levels.ERROR)
    return
  end

  local tree = parser:parse()[1]
  local node = tree:root():named_descendant_for_range(row, col, row, col)
  local function_node
  local classes = {}

  while node do
    local node_type = node:type()
    if node_type == "function_declaration" then
      function_node = node
    elseif node_type == "class_declaration" or node_type == "object_declaration" then
      table.insert(classes, 1, node)
    end
    node = node:parent()
  end

  local package_name
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for _, line in ipairs(lines) do
    package_name = line:match("^%s*package%s+([%w_%.]+)")
    if package_name then
      break
    end
  end

  if #classes == 0 then
    vim.notify("Cursor is not inside a Kotlin class", vim.log.levels.WARN)
    return
  end

  local class_names = {}
  for _, class_node in ipairs(classes) do
    local name = declaration_name(class_node)
    if name then
      table.insert(class_names, vim.treesitter.get_node_text(name, bufnr))
    end
  end
  if #class_names ~= #classes then
    vim.notify("Could not determine the enclosing class name", vim.log.levels.ERROR)
    return
  end

  local filter = (package_name and (package_name .. ".") or "") .. table.concat(class_names, "$")
  if function_node then
    local function_name = declaration_name(function_node)
    if not function_name then
      vim.notify("Could not determine the function name", vim.log.levels.ERROR)
      return
    end
    filter = filter .. "." .. vim.treesitter.get_node_text(function_name, bufnr)
  end

  vim.fn.setreg("+", filter)

  local path = vim.api.nvim_buf_get_name(bufnr)
  local dir = path ~= "" and vim.fn.fnamemodify(path, ":p:h") or vim.fn.getcwd()
  local project_root
  local build_dir
  while dir and dir ~= "" do
    if
      vim.fn.filereadable(dir .. "/gradlew") == 1
      or vim.fn.filereadable(dir .. "/settings.gradle") == 1
      or vim.fn.filereadable(dir .. "/settings.gradle.kts") == 1
    then
      project_root = dir
      break
    end
    if
      not build_dir
      and (vim.fn.filereadable(dir .. "/build.gradle") == 1 or vim.fn.filereadable(dir .. "/build.gradle.kts") == 1)
    then
      build_dir = dir
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then
      break
    end
    dir = parent
  end
  project_root = project_root or build_dir
  if not project_root then
    vim.notify("Could not find a Gradle project root", vim.log.levels.ERROR)
    return
  end

  local gradlew = project_root .. "/gradlew"
  local command
  if vim.fn.executable(gradlew) == 1 then
    command = { gradlew, "test", "--tests", filter }
  elseif vim.fn.executable("gradle") == 1 then
    command = { "gradle", "test", "--tests", filter }
  else
    vim.notify("Gradle wrapper or gradle executable is required", vim.log.levels.ERROR)
    return
  end

  local width = math.floor(vim.o.columns * 0.85)
  local height = math.floor(vim.o.lines * 0.8)
  local win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
  })
  local terminal_buf = vim.api.nvim_win_get_buf(win)
  vim.bo[terminal_buf].bufhidden = "hide"
  local job = vim.fn.jobstart(command, { cwd = project_root, term = true })
  if job <= 0 then
    vim.api.nvim_win_close(win, true)
    vim.notify("Failed to start Gradle tests", vim.log.levels.ERROR)
    return
  end
  vim.notify("Running Gradle test filter: " .. filter)
end

vim.api.nvim_create_user_command("RunGradleTestAtCursor", run_gradle_test_at_cursor, {})
vim.api.nvim_create_autocmd("FileType", {
  pattern = "kotlin",
  callback = function(event)
    vim.keymap.set("n", "<leader>t", "<cmd>RunGradleTestAtCursor<cr>", {
      buffer = event.buf,
      desc = "Run Gradle test",
    })
  end,
})

return {}
