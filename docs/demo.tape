# Shazam CLI Demo
# Run with: vhs docs/demo.tape

Output docs/images/demo.gif
Set Theme "Catppuccin Mocha"
Set Width 900
Set Height 500
Set FontSize 14
Set TypingSpeed 50ms
Set Padding 10
Set Shell "zsh"

# Add shazam to PATH
Type "export PATH=$HOME/bin:$HOME/.cargo/bin:$PATH"
Enter
Sleep 500ms

# Start shazam shell
Type "shazam shell"
Enter
Sleep 3s

# Start agents
Type "/start"
Enter
Sleep 2s

# Create a task
Type "Create a simple hello world REST API with a /health endpoint"
Enter
Sleep 4s

# Show tasks overlay
Type "/tasks"
Enter
Sleep 3s

# Close overlay
Escape
Sleep 1s

# Approve all
Type "/aa"
Enter
Sleep 3s

# Show dashboard
Type "/dashboard"
Enter
Sleep 4s

# Close and show agents
Escape
Sleep 1s
Type "/agents"
Enter
Sleep 3s

Escape
Sleep 1s

# Exit
Type "/quit"
Enter
Sleep 1s
