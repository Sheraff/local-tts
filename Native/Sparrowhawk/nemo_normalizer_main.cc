// Native NeMo TN runtime for Local TTS.
//
// This intentionally mirrors NeMo's Python normalization flow:
// 1. classifier WFST: written text -> token stream
// 2. token parser + field permutation
// 3. final verbalizer WFST: token stream -> spoken text

#include <algorithm>
#include <iostream>
#include <memory>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include <sparrowhawk/rule_system.h>

namespace {

using speech::sparrowhawk::RuleSystem;

constexpr int kMaxPermutationsPerSplit = 729;

struct Node {
  enum class Kind { String, Bool, Object };

  Kind kind = Kind::Object;
  std::string string_value;
  bool bool_value = false;
  std::vector<std::pair<std::string, Node>> object_value;

  static Node String(std::string value) {
    Node node;
    node.kind = Kind::String;
    node.string_value = std::move(value);
    return node;
  }

  static Node Bool(bool value) {
    Node node;
    node.kind = Kind::Bool;
    node.bool_value = value;
    return node;
  }

  static Node Object(std::vector<std::pair<std::string, Node>> value) {
    Node node;
    node.kind = Kind::Object;
    node.object_value = std::move(value);
    return node;
  }
};

class TokenParser {
 public:
  explicit TokenParser(std::string text) : text_(std::move(text)) {}

  std::vector<Node> Parse() {
    std::vector<Node> tokens;
    while (ParseWhitespace()) {
      auto token = ParseToken();
      if (!token.has_value()) break;
      tokens.push_back(std::move(*token));
    }
    return tokens;
  }

 private:
  std::optional<Node> ParseToken() {
    auto key = ParseKey();
    if (!key.has_value()) return std::nullopt;
    ParseWhitespace();

    Node value;
    if (*key == "preserve_order") {
      Expect(':');
      ParseWhitespace();
      ExpectLiteral("true");
      value = Node::Bool(true);
    } else {
      value = ParseValue();
    }

    std::vector<std::pair<std::string, Node>> fields;
    fields.emplace_back(std::move(*key), std::move(value));
    return Node::Object(std::move(fields));
  }

  Node ParseValue() {
    if (Peek() == ':') {
      Advance();
      ParseWhitespace();
      Expect('"');
      std::string value = ParseStringValue();
      Expect('"');
      return Node::String(std::move(value));
    }
    if (Peek() == '{') {
      Advance();
      std::vector<std::pair<std::string, Node>> fields;
      for (Node& token : Parse()) {
        for (auto& field : token.object_value) {
          fields.emplace_back(std::move(field));
        }
      }
      Expect('}');
      return Node::Object(std::move(fields));
    }
    throw std::runtime_error("unexpected token value");
  }

  std::optional<std::string> ParseKey() {
    if (AtEnd() || IsWhitespace(Peek())) return std::nullopt;
    std::string key;
    while (!AtEnd()) {
      char ch = Peek();
      if ((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || ch == '_') {
        key.push_back(ch);
        Advance();
      } else {
        break;
      }
    }
    if (key.empty()) return std::nullopt;
    return key;
  }

  std::string ParseStringValue() {
    std::string value;
    while (!AtEnd()) {
      if (Peek() == '"' && index_ + 1 < text_.size() && text_[index_ + 1] == ' ') {
        return value;
      }
      value.push_back(Peek());
      Advance();
    }
    throw std::runtime_error("unterminated string value");
  }

  bool ParseWhitespace() {
    while (!AtEnd() && IsWhitespace(Peek())) Advance();
    return !AtEnd();
  }

  void Expect(char expected) {
    if (AtEnd() || Peek() != expected) {
      std::ostringstream message;
      message << "expected '" << expected << "'";
      throw std::runtime_error(message.str());
    }
    Advance();
  }

  void ExpectLiteral(const std::string& expected) {
    for (char ch : expected) Expect(ch);
  }

  char Peek() const { return text_[index_]; }
  bool AtEnd() const { return index_ >= text_.size(); }
  void Advance() { ++index_; }

  static bool IsWhitespace(char ch) {
    return ch == ' ' || ch == '\n' || ch == '\t' || ch == '\r';
  }

  std::string text_;
  size_t index_ = 0;
};

int EstimatePermutations(const Node& node) {
  if (node.kind != Node::Kind::Object) return 1;
  int result = 1;
  for (const auto& field : node.object_value) {
    result *= EstimatePermutations(field.second);
  }
  int factorial = 1;
  for (size_t i = 2; i <= node.object_value.size(); ++i) {
    factorial *= static_cast<int>(i);
  }
  return result * factorial;
}

bool HasPreserveOrder(const Node& node) {
  if (node.kind != Node::Kind::Object) return false;
  return std::any_of(
      node.object_value.begin(),
      node.object_value.end(),
      [](const auto& field) { return field.first == "preserve_order"; });
}

std::vector<std::string> Permute(const Node& node);

std::vector<std::string> RenderOrderedFields(
    const std::vector<std::pair<std::string, Node>>& fields) {
  std::vector<std::string> outputs{""};
  for (const auto& field : fields) {
    std::vector<std::string> fragments;
    if (field.second.kind == Node::Kind::String) {
      fragments.push_back(field.first + ": \"" + field.second.string_value + "\" ");
    } else if (field.second.kind == Node::Kind::Bool) {
      fragments.push_back(field.first + ": true ");
    } else {
      for (const auto& nested : Permute(field.second)) {
        fragments.push_back(" " + field.first + " { " + nested + " } ");
      }
    }

    std::vector<std::string> next;
    for (const auto& prefix : outputs) {
      for (const auto& fragment : fragments) {
        next.push_back(prefix + fragment);
      }
    }
    outputs = std::move(next);
  }
  return outputs;
}

std::vector<std::string> Permute(const Node& node) {
  if (node.kind != Node::Kind::Object) return {""};
  if (HasPreserveOrder(node)) return RenderOrderedFields(node.object_value);

  std::vector<int> order(node.object_value.size());
  for (size_t i = 0; i < order.size(); ++i) order[i] = static_cast<int>(i);

  std::vector<std::string> outputs;
  do {
    std::vector<std::pair<std::string, Node>> ordered;
    ordered.reserve(order.size());
    for (int index : order) ordered.push_back(node.object_value[index]);
    auto rendered = RenderOrderedFields(ordered);
    outputs.insert(outputs.end(), rendered.begin(), rendered.end());
  } while (std::next_permutation(order.begin(), order.end()));
  return outputs;
}

std::vector<std::vector<Node>> SplitTokens(const std::vector<Node>& tokens) {
  std::vector<std::vector<Node>> splits;
  size_t split_start = 0;
  int current_permutations = 1;
  for (size_t i = 0; i < tokens.size(); ++i) {
    int token_permutations = EstimatePermutations(tokens[i]);
    if (token_permutations * current_permutations > kMaxPermutationsPerSplit &&
        split_start < i) {
      splits.emplace_back(tokens.begin() + split_start, tokens.begin() + i);
      split_start = i;
      current_permutations = 1;
    }
    current_permutations *= token_permutations;
  }
  splits.emplace_back(tokens.begin() + split_start, tokens.end());
  return splits;
}

void GenerateTokenPermutations(
    const std::vector<Node>& tokens,
    size_t index,
    std::string prefix,
    std::vector<std::string>* outputs) {
  if (index == tokens.size()) {
    outputs->push_back(std::move(prefix));
    return;
  }
  for (const auto& option : Permute(tokens[index])) {
    GenerateTokenPermutations(tokens, index + 1, prefix + option, outputs);
  }
}

std::string PrepareForWFST(std::string text) {
  std::string output;
  output.reserve(text.size() + 8);
  for (size_t i = 0; i < text.size();) {
    const bool is_times = i + 1 < text.size() &&
        static_cast<unsigned char>(text[i]) == 0xC3 &&
        static_cast<unsigned char>(text[i + 1]) == 0x97;
    if (is_times) {
      if (!output.empty() && output.back() != ' ') output.push_back(' ');
      output += "times";
      if (i + 2 < text.size() && text[i + 2] != ' ') output.push_back(' ');
      i += 2;
      continue;
    }
    output.push_back(text[i]);
    ++i;
  }
  return output;
}

std::string CleanupPunctuation(std::string text) {
  std::string output;
  output.reserve(text.size());
  for (char ch : text) {
    if ((ch == '.' || ch == ',' || ch == ';' || ch == ':' ||
         ch == '!' || ch == '?') &&
        !output.empty() && output.back() == ' ') {
      output.pop_back();
    }
    output.push_back(ch);
  }
  return output;
}

bool NormalizeLine(
    const std::string& line,
    const RuleSystem& classifier,
    const RuleSystem& verbalizer,
    std::string* normalized) {
  std::string tagged;
  if (!classifier.ApplyRules(PrepareForWFST(line), &tagged, true)) {
    return false;
  }
  TokenParser parser(tagged);
  std::vector<Node> tokens = parser.Parse();
  std::string output;
  for (const auto& split : SplitTokens(tokens)) {
    std::vector<std::string> permutations;
    GenerateTokenPermutations(split, 0, "", &permutations);

    bool matched = false;
    for (const auto& candidate : permutations) {
      std::string partial;
      if (verbalizer.ApplyRules(candidate, &partial, false)) {
        if (!output.empty()) output.push_back(' ');
        output += partial;
        matched = true;
        break;
      }
    }
    if (!matched) return false;
  }

  *normalized = CleanupPunctuation(output);
  return true;
}

std::string EnsureTrailingSlash(std::string path) {
  if (!path.empty() && path.back() != '/') path.push_back('/');
  return path;
}

}  // namespace

int main(int argc, char** argv) {
  std::string path_prefix = "./";
  bool strict = false;
  for (int i = 1; i < argc; ++i) {
    std::string arg(argv[i]);
    const std::string flag = "--path_prefix=";
    if (arg.rfind(flag, 0) == 0) {
      path_prefix = arg.substr(flag.size());
    } else if (arg == "--strict") {
      strict = true;
    }
  }
  path_prefix = EnsureTrailingSlash(path_prefix);

  RuleSystem classifier;
  if (!classifier.LoadGrammar("tokenizer.ascii_proto", path_prefix)) {
    std::cerr << "failed to load tokenizer grammar\n";
    return 1;
  }
  RuleSystem verbalizer;
  if (!verbalizer.LoadGrammar("verbalizer_final.ascii_proto", path_prefix)) {
    std::cerr << "failed to load verbalizer grammar\n";
    return 1;
  }

  std::string line;
  while (std::getline(std::cin, line)) {
    if (line.find_first_not_of(" \t\r\n") == std::string::npos) {
      std::cout << "\n";
      continue;
    }
    std::string normalized;
    if (!NormalizeLine(line, classifier, verbalizer, &normalized)) {
      std::cerr << "failed to normalize line, using original text: " << line << "\n";
      if (strict) return 1;
      normalized = CleanupPunctuation(PrepareForWFST(line));
    }
    std::cout << normalized << "\n";
  }
  return 0;
}
