/// Reads one prompt. The caller owns the returned allocation (free with free()).
char *agent_read_prompt(const char *prompt, const char *history_path);
