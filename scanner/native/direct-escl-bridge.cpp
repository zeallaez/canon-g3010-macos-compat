/*
 * Canon G3010 direct eSCL bridge
 *
 * Copyright (c) 2026 Canon G3010 macOS Compat contributors
 * SPDX-License-Identifier: MIT
 *
 * This deliberately small HTTP service translates the eSCL surface used by
 * macOS Image Capture into one native scanimage invocation. scanimage then
 * talks to the printer's WSD Scan endpoint through sane-airscan.
 */

#include <arpa/inet.h>
#include <netinet/in.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cctype>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <map>
#include <memory>
#include <mutex>
#include <random>
#include <regex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace {

constexpr int kMaxRequestBytes = 1024 * 1024;
constexpr int kMaxWidth300 = 2550;
constexpr int kMaxHeight300 = 3504;

struct Options {
  int port = 8090;
  std::string runtime_dir;
  std::string config_dir;
  std::string printer_ip;
  std::string uuid;
  std::string service_name = "Canon G3010 series";
};

enum class JobState { pending, processing, completed, aborted, canceled };

struct Job {
  std::string id;
  std::string document_format = "image/jpeg";
  std::string color_mode = "Color";
  int resolution = 300;
  double left_mm = 0;
  double top_mm = 0;
  double width_mm = 215.9;
  double height_mm = 296.672;
  std::atomic<JobState> state{JobState::pending};
  std::atomic<pid_t> child_pid{-1};
  std::atomic<int> images_completed{0};
  std::string reason = "JobQueued";
  std::chrono::steady_clock::time_point created =
      std::chrono::steady_clock::now();
};

Options g_options;
std::atomic<bool> g_running{true};
std::atomic<int> g_listen_fd{-1};
std::mutex g_jobs_mutex;
std::map<std::string, std::shared_ptr<Job>> g_jobs;

std::string trim(std::string value) {
  while (!value.empty() &&
         std::isspace(static_cast<unsigned char>(value.front()))) {
    value.erase(value.begin());
  }
  while (!value.empty() &&
         std::isspace(static_cast<unsigned char>(value.back()))) {
    value.pop_back();
  }
  return value;
}

std::string lowercase(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
    return static_cast<char>(std::tolower(c));
  });
  return value;
}

std::string xml_escape(const std::string &value) {
  std::string result;
  for (char c : value) {
    switch (c) {
      case '&':
        result += "&amp;";
        break;
      case '<':
        result += "&lt;";
        break;
      case '>':
        result += "&gt;";
        break;
      case '"':
        result += "&quot;";
        break;
      case '\'':
        result += "&apos;";
        break;
      default:
        result += c;
    }
  }
  return result;
}

std::string xml_value(const std::string &xml, const std::string &name) {
  const std::regex expression(
      "<(?:[A-Za-z_][A-Za-z0-9_.-]*:)?" + name +
          "(?:\\s[^>]*)?>([^<]*)</(?:[A-Za-z_][A-Za-z0-9_.-]*:)?" +
          name + ">",
      std::regex::icase);
  std::smatch match;
  if (std::regex_search(xml, match, expression) && match.size() == 2) {
    return trim(match[1].str());
  }
  return "";
}

double xml_number(const std::string &xml, const std::string &name,
                  double fallback) {
  const std::string text = xml_value(xml, name);
  if (text.empty()) {
    return fallback;
  }
  try {
    return std::stod(text);
  } catch (...) {
    return fallback;
  }
}

std::string new_uuid() {
  std::random_device random;
  std::uniform_int_distribution<int> byte(0, 255);
  unsigned char data[16];
  for (auto &value : data) {
    value = static_cast<unsigned char>(byte(random));
  }
  data[6] = static_cast<unsigned char>((data[6] & 0x0f) | 0x40);
  data[8] = static_cast<unsigned char>((data[8] & 0x3f) | 0x80);

  std::ostringstream output;
  output << std::hex << std::setfill('0');
  for (int i = 0; i < 16; ++i) {
    if (i == 4 || i == 6 || i == 8 || i == 10) {
      output << '-';
    }
    output << std::setw(2) << static_cast<int>(data[i]);
  }
  return output.str();
}

bool send_all(int fd, const void *data, size_t size) {
  const char *cursor = static_cast<const char *>(data);
  while (size > 0) {
    const ssize_t sent = send(fd, cursor, size, 0);
    if (sent <= 0) {
      if (errno == EINTR) {
        continue;
      }
      return false;
    }
    cursor += sent;
    size -= static_cast<size_t>(sent);
  }
  return true;
}

std::string status_text(int status) {
  switch (status) {
    case 200:
      return "OK";
    case 201:
      return "Created";
    case 400:
      return "Bad Request";
    case 404:
      return "Not Found";
    case 409:
      return "Conflict";
    case 500:
      return "Internal Server Error";
    case 503:
      return "Service Unavailable";
    default:
      return "Error";
  }
}

void send_response(
    int fd, int status, const std::string &content_type,
    const std::string &body,
    const std::vector<std::pair<std::string, std::string>> &headers = {}) {
  std::ostringstream response;
  response << "HTTP/1.1 " << status << ' ' << status_text(status) << "\r\n"
           << "Server: Canon-G3010-eSCL/1.4\r\n"
           << "Connection: close\r\n";
  if (!content_type.empty()) {
    response << "Content-Type: " << content_type << "\r\n";
  }
  for (const auto &header : headers) {
    response << header.first << ": " << header.second << "\r\n";
  }
  response << "Content-Length: " << body.size() << "\r\n\r\n" << body;
  const std::string serialized = response.str();
  send_all(fd, serialized.data(), serialized.size());
}

bool send_file(int fd, const std::string &path,
               const std::string &content_type) {
  struct stat info {};
  if (stat(path.c_str(), &info) != 0 || info.st_size < 1) {
    return false;
  }
  std::ostringstream header;
  header << "HTTP/1.1 200 OK\r\n"
         << "Server: Canon-G3010-eSCL/1.4\r\n"
         << "Connection: close\r\n"
         << "Content-Type: " << content_type << "\r\n"
         << "Transfer-Encoding: chunked\r\n\r\n";
  const std::string serialized = header.str();
  if (!send_all(fd, serialized.data(), serialized.size())) {
    return false;
  }

  std::ifstream input(path, std::ios::binary);
  char buffer[64 * 1024];
  while (input) {
    input.read(buffer, sizeof(buffer));
    const std::streamsize count = input.gcount();
    if (count > 0) {
      std::ostringstream chunk_header;
      chunk_header << std::hex << count << "\r\n";
      const std::string serialized_chunk_header = chunk_header.str();
      if (!send_all(fd, serialized_chunk_header.data(),
                    serialized_chunk_header.size()) ||
          !send_all(fd, buffer, static_cast<size_t>(count)) ||
          !send_all(fd, "\r\n", 2)) {
        return false;
      }
    }
  }
  return send_all(fd, "0\r\n\r\n", 5);
}

struct Request {
  std::string method;
  std::string path;
  std::map<std::string, std::string> headers;
  std::string body;
};

bool read_request(int fd, Request &request) {
  std::string data;
  char buffer[8192];
  size_t header_end = std::string::npos;
  size_t delimiter_size = 4;

  while (data.size() < kMaxRequestBytes) {
    const ssize_t count = recv(fd, buffer, sizeof(buffer), 0);
    if (count < 0) {
      if (errno == EINTR) {
        continue;
      }
      return false;
    }
    if (count == 0) {
      break;
    }
    data.append(buffer, static_cast<size_t>(count));
    header_end = data.find("\r\n\r\n");
    if (header_end == std::string::npos) {
      header_end = data.find("\n\n");
      delimiter_size = 2;
    }
    if (header_end != std::string::npos) {
      break;
    }
  }
  if (header_end == std::string::npos) {
    return false;
  }

  std::istringstream header_stream(data.substr(0, header_end));
  std::string line;
  if (!std::getline(header_stream, line)) {
    return false;
  }
  line = trim(line);
  std::istringstream request_line(line);
  std::string version;
  request_line >> request.method >> request.path >> version;
  if (request.method.empty() || request.path.empty()) {
    return false;
  }

  while (std::getline(header_stream, line)) {
    line = trim(line);
    const size_t colon = line.find(':');
    if (colon == std::string::npos) {
      continue;
    }
    request.headers[lowercase(trim(line.substr(0, colon)))] =
        trim(line.substr(colon + 1));
  }

  size_t content_length = 0;
  const auto length = request.headers.find("content-length");
  if (length != request.headers.end()) {
    try {
      content_length = static_cast<size_t>(std::stoul(length->second));
    } catch (...) {
      return false;
    }
  }
  if (content_length > kMaxRequestBytes) {
    return false;
  }

  const size_t body_start = header_end + delimiter_size;
  request.body = data.substr(body_start);
  while (request.body.size() < content_length) {
    const ssize_t count = recv(fd, buffer, sizeof(buffer), 0);
    if (count <= 0) {
      return false;
    }
    request.body.append(buffer, static_cast<size_t>(count));
  }
  if (request.body.size() > content_length) {
    request.body.resize(content_length);
  }
  return true;
}

std::string capabilities_xml() {
  std::ostringstream xml;
  xml << "<?xml version='1.0' encoding='UTF-8'?>\r\n"
      << "<scan:ScannerCapabilities "
      << "xmlns:pwg='http://www.pwg.org/schemas/2010/12/sm' "
      << "xmlns:scan='http://schemas.hp.com/imaging/escl/2011/05/03'>\r\n"
      << "<pwg:Version>2.0</pwg:Version>\r\n"
      << "<pwg:MakeAndModel>" << xml_escape(g_options.service_name)
      << "</pwg:MakeAndModel>\r\n"
      << "<pwg:SerialNumber>" << xml_escape(g_options.uuid)
      << "</pwg:SerialNumber>\r\n"
      << "<scan:UUID>" << xml_escape(g_options.uuid) << "</scan:UUID>\r\n"
      << "<scan:AdminURI>http://127.0.0.1:" << g_options.port
      << "/eSCL</scan:AdminURI>\r\n"
      << "<scan:Platen><scan:PlatenInputCaps>\r\n"
      << "<scan:MinWidth>0</scan:MinWidth><scan:MinHeight>0</scan:MinHeight>\r\n"
      << "<scan:MaxWidth>" << kMaxWidth300 << "</scan:MaxWidth>\r\n"
      << "<scan:MaxHeight>" << kMaxHeight300 << "</scan:MaxHeight>\r\n"
      << "<scan:MaxPhysicalWidth>" << kMaxWidth300
      << "</scan:MaxPhysicalWidth>\r\n"
      << "<scan:MaxPhysicalHeight>" << kMaxHeight300
      << "</scan:MaxPhysicalHeight>\r\n"
      << "<scan:MaxScanRegions>1</scan:MaxScanRegions>\r\n"
      << "<scan:SettingProfiles><scan:SettingProfile name='0'>\r\n"
      << "<scan:ColorModes><scan:ColorMode>Grayscale8</scan:ColorMode>"
      << "<scan:ColorMode>RGB24</scan:ColorMode></scan:ColorModes>\r\n"
      << "<scan:ColorSpaces><scan:ColorSpace>RGB</scan:ColorSpace>"
      << "</scan:ColorSpaces>\r\n"
      << "<scan:SupportedResolutions><scan:DiscreteResolutions>\r\n";
  for (int dpi : {150, 300, 600}) {
    xml << "<scan:DiscreteResolution><scan:XResolution>" << dpi
        << "</scan:XResolution><scan:YResolution>" << dpi
        << "</scan:YResolution></scan:DiscreteResolution>\r\n";
  }
  xml << "</scan:DiscreteResolutions></scan:SupportedResolutions>\r\n"
      << "<scan:DocumentFormats>"
      << "<pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat>"
      << "<pwg:DocumentFormat>image/png</pwg:DocumentFormat>"
      << "</scan:DocumentFormats>\r\n"
      << "</scan:SettingProfile></scan:SettingProfiles>\r\n"
      << "<scan:SupportedIntents>"
      << "<scan:SupportedIntent>Preview</scan:SupportedIntent>"
      << "<scan:SupportedIntent>TextAndGraphic</scan:SupportedIntent>"
      << "<scan:SupportedIntent>Photo</scan:SupportedIntent>"
      << "</scan:SupportedIntents>\r\n"
      << "</scan:PlatenInputCaps></scan:Platen>\r\n"
      << "</scan:ScannerCapabilities>\r\n";
  return xml.str();
}

std::string job_state_text(JobState state) {
  switch (state) {
    case JobState::pending:
      return "Pending";
    case JobState::processing:
      return "Processing";
    case JobState::completed:
      return "Completed";
    case JobState::canceled:
      return "Canceled";
    case JobState::aborted:
      return "Aborted";
  }
  return "Aborted";
}

std::string scanner_status_xml() {
  std::ostringstream xml;
  bool processing = false;
  {
    std::lock_guard<std::mutex> lock(g_jobs_mutex);
    for (const auto &entry : g_jobs) {
      if (entry.second->state == JobState::processing) {
        processing = true;
      }
    }
  }

  xml << "<?xml version='1.0' encoding='UTF-8'?>\r\n"
      << "<scan:ScannerStatus "
      << "xmlns:pwg='http://www.pwg.org/schemas/2010/12/sm' "
      << "xmlns:scan='http://schemas.hp.com/imaging/escl/2011/05/03'>\r\n"
      << "<pwg:Version>2.0</pwg:Version><pwg:State>"
      << (processing ? "Processing" : "Idle")
      << "</pwg:State><scan:Jobs>\r\n";

  std::lock_guard<std::mutex> lock(g_jobs_mutex);
  for (const auto &entry : g_jobs) {
    const auto &job = entry.second;
    const auto age = std::chrono::duration_cast<std::chrono::seconds>(
                         std::chrono::steady_clock::now() - job->created)
                         .count();
    xml << "<scan:JobInfo><pwg:JobUri>/eSCL/ScanJobs/" << job->id
        << "</pwg:JobUri><pwg:JobUuid>" << job->id
        << "</pwg:JobUuid><pwg:Age>" << age
        << "</pwg:Age><pwg:JobState>" << job_state_text(job->state)
        << "</pwg:JobState><pwg:ImagesCompleted>" << job->images_completed
        << "</pwg:ImagesCompleted><pwg:JobStateReasons>"
        << "<pwg:JobStateReason>" << xml_escape(job->reason)
        << "</pwg:JobStateReason></pwg:JobStateReasons></scan:JobInfo>\r\n";
  }
  xml << "</scan:Jobs></scan:ScannerStatus>\r\n";
  return xml.str();
}

std::shared_ptr<Job> create_job(const std::string &ticket) {
  auto job = std::make_shared<Job>();
  job->id = new_uuid();

  int dpi = static_cast<int>(xml_number(ticket, "XResolution", 300));
  if (dpi != 150 && dpi != 300 && dpi != 600) {
    dpi = 300;
  }
  job->resolution = dpi;

  const std::string color = xml_value(ticket, "ColorMode");
  job->color_mode =
      lowercase(color).find("gray") != std::string::npos ? "Gray" : "Color";

  const std::string format = lowercase(
      xml_value(ticket, "DocumentFormat").empty()
          ? xml_value(ticket, "DocumentFormatExt")
          : xml_value(ticket, "DocumentFormat"));
  job->document_format =
      format == "image/png" ? "image/png" : "image/jpeg";

  const bool three_hundredths =
      xml_value(ticket, "ContentRegionUnits") ==
      "escl:ThreeHundredthsOfInches";
  const double unit_to_mm = three_hundredths ? 25.4 / 300.0 : 25.4 / dpi;
  job->left_mm = std::max(0.0, xml_number(ticket, "XOffset", 0) * unit_to_mm);
  job->top_mm = std::max(0.0, xml_number(ticket, "YOffset", 0) * unit_to_mm);
  job->width_mm =
      xml_number(ticket, "Width", kMaxWidth300) * unit_to_mm;
  job->height_mm =
      xml_number(ticket, "Height", kMaxHeight300) * unit_to_mm;
  job->width_mm = std::clamp(job->width_mm, 1.0, 215.9 - job->left_mm);
  job->height_mm =
      std::clamp(job->height_mm, 1.0, 296.672 - job->top_mm);

  std::lock_guard<std::mutex> lock(g_jobs_mutex);
  g_jobs[job->id] = job;
  std::clog << "created job " << job->id << ": " << job->document_format
            << ", " << job->color_mode << ", " << job->resolution << " dpi, "
            << job->width_mm << "x" << job->height_mm << " mm\n";
  return job;
}

std::shared_ptr<Job> find_job(const std::string &id) {
  std::lock_guard<std::mutex> lock(g_jobs_mutex);
  const auto found = g_jobs.find(id);
  return found == g_jobs.end() ? nullptr : found->second;
}

bool run_scan(const std::shared_ptr<Job> &job, std::string &output_path) {
  if (job->state != JobState::pending) {
    return false;
  }
  job->state = JobState::processing;
  job->reason = "JobScanning";

  const std::string extension =
      job->document_format == "image/png" ? "png" : "jpg";
  output_path =
      "/private/tmp/canon-g3010-escl-" + job->id + "." + extension;
  const std::string scanimage = g_options.runtime_dir + "/bin/scanimage";

  std::vector<std::string> arguments = {
      scanimage,
      "-d",
      "airscan:w0:Canon G3010 WSD",
      "--resolution",
      std::to_string(job->resolution),
      "--mode",
      job->color_mode,
      "--format",
      extension == "png" ? "png" : "jpeg",
      "-l",
      std::to_string(job->left_mm),
      "-t",
      std::to_string(job->top_mm),
      "-x",
      std::to_string(job->width_mm),
      "-y",
      std::to_string(job->height_mm),
      "--output-file",
      output_path,
  };

  const pid_t child = fork();
  if (child == 0) {
    setenv("SANE_CONFIG_DIR", g_options.config_dir.c_str(), 1);
    const std::string backend_dir = g_options.runtime_dir + "/lib/sane";
    setenv("LD_LIBRARY_PATH", backend_dir.c_str(), 1);
    setenv("DYLD_LIBRARY_PATH", backend_dir.c_str(), 1);
    std::vector<char *> argv;
    for (auto &argument : arguments) {
      argv.push_back(argument.data());
    }
    argv.push_back(nullptr);
    execv(scanimage.c_str(), argv.data());
    _exit(127);
  }
  if (child < 0) {
    job->state = JobState::aborted;
    job->reason = "ResourcesAreNotReady";
    return false;
  }

  job->child_pid = child;
  int status = 0;
  while (waitpid(child, &status, 0) < 0 && errno == EINTR) {
  }
  job->child_pid = -1;

  struct stat output {};
  const bool success =
      WIFEXITED(status) && WEXITSTATUS(status) == 0 &&
      stat(output_path.c_str(), &output) == 0 && output.st_size > 0;
  if (!success) {
    if (job->state != JobState::canceled) {
      job->state = JobState::aborted;
      job->reason = "ErrorsDetected";
    }
    unlink(output_path.c_str());
    std::cerr << "scan job " << job->id << " failed with wait status "
              << status << "\n";
    return false;
  }
  std::clog << "scan job " << job->id << " completed\n";
  return true;
}

void complete_job(const std::shared_ptr<Job> &job) {
  job->images_completed = 1;
  job->reason = "JobCompletedSuccessfully";
  job->state = JobState::completed;
}

void handle_request(int fd) {
  Request request;
  if (!read_request(fd, request)) {
    send_response(fd, 400, "text/plain", "Invalid HTTP request\n");
    close(fd);
    return;
  }

  const size_t query = request.path.find('?');
  if (query != std::string::npos) {
    request.path.resize(query);
  }
  if (request.path != "/eSCL/ScannerStatus") {
    std::clog << request.method << " " << request.path << "\n";
  }

  if (request.method == "GET" &&
      request.path == "/eSCL/ScannerCapabilities") {
    send_response(fd, 200, "text/xml", capabilities_xml());
  } else if (request.method == "GET" &&
             request.path == "/eSCL/ScannerStatus") {
    send_response(fd, 200, "text/xml", scanner_status_xml());
  } else if (request.method == "POST" &&
             request.path == "/eSCL/ScanJobs") {
    const auto job = create_job(request.body);
    send_response(fd, 201, "", "",
                  {{"Location", "/eSCL/ScanJobs/" + job->id}});
  } else {
    const std::regex next_document(
        "^/eSCL/ScanJobs/([0-9a-fA-F-]+)/NextDocument$");
    const std::regex job_path("^/eSCL/ScanJobs/([0-9a-fA-F-]+)$");
    std::smatch match;
    if (request.method == "GET" &&
        std::regex_match(request.path, match, next_document)) {
      const auto job = find_job(match[1].str());
      if (!job) {
        send_response(fd, 404, "text/plain", "Unknown scan job\n");
      } else if (job->state == JobState::completed ||
                 job->state == JobState::canceled) {
        send_response(fd, 404, "", "");
      } else if (job->state == JobState::aborted) {
        send_response(fd, 409, "text/plain", "Scan job aborted\n");
      } else {
        std::string output_path;
        if (!run_scan(job, output_path)) {
          send_response(fd, 503, "text/plain", "Scan failed\n");
        } else {
          const bool sent =
              send_file(fd, output_path, job->document_format);
          unlink(output_path.c_str());
          complete_job(job);
          if (!sent) {
            std::cerr << "client disconnected while receiving " << job->id
                      << "\n";
          }
        }
      }
    } else if (request.method == "DELETE" &&
               std::regex_match(request.path, match, job_path)) {
      const auto job = find_job(match[1].str());
      if (!job) {
        send_response(fd, 404, "text/plain", "Unknown scan job\n");
      } else {
        const pid_t child = job->child_pid;
        if (child > 0) {
          kill(child, SIGTERM);
        }
        if (job->state != JobState::completed) {
          job->reason = "JobCanceledByUser";
          job->state = JobState::canceled;
        }
        send_response(fd, 200, "", "");
        std::lock_guard<std::mutex> lock(g_jobs_mutex);
        g_jobs.erase(job->id);
      }
    } else if (request.method == "GET" &&
               (request.path == "/" || request.path == "/eSCL" ||
                request.path == "/eSCL/")) {
      send_response(fd, 200, "text/plain",
                    "Canon G3010 native eSCL bridge\n");
    } else {
      send_response(fd, 404, "text/plain", "Not found\n");
    }
  }
  close(fd);
}

void handle_signal(int) {
  g_running = false;
  const int fd = g_listen_fd.exchange(-1);
  if (fd >= 0) {
    close(fd);
  }
}

bool parse_arguments(int argc, char **argv) {
  for (int i = 1; i < argc; ++i) {
    const std::string argument = argv[i];
    auto require_value = [&](std::string &destination) {
      if (i + 1 >= argc) {
        return false;
      }
      destination = argv[++i];
      return true;
    };

    if (argument == "--listen-port") {
      std::string value;
      if (!require_value(value)) {
        return false;
      }
      try {
        g_options.port = std::stoi(value);
      } catch (...) {
        return false;
      }
    } else if (argument == "--runtime-dir") {
      if (!require_value(g_options.runtime_dir)) {
        return false;
      }
    } else if (argument == "--config-dir") {
      if (!require_value(g_options.config_dir)) {
        return false;
      }
    } else if (argument == "--printer-ip") {
      if (!require_value(g_options.printer_ip)) {
        return false;
      }
    } else if (argument == "--uuid") {
      if (!require_value(g_options.uuid)) {
        return false;
      }
    } else if (argument == "--service-name") {
      if (!require_value(g_options.service_name)) {
        return false;
      }
    } else if (argument == "--help") {
      return false;
    } else {
      std::cerr << "unknown argument: " << argument << "\n";
      return false;
    }
  }
  return g_options.port > 0 && g_options.port <= 65535 &&
         !g_options.runtime_dir.empty() && !g_options.config_dir.empty() &&
         !g_options.printer_ip.empty() && !g_options.uuid.empty();
}

}  // namespace

int main(int argc, char **argv) {
  if (!parse_arguments(argc, argv)) {
    std::cerr
        << "Usage: canon-g3010-escl-bridge --listen-port PORT "
        << "--runtime-dir DIR --config-dir DIR --printer-ip ADDRESS "
        << "--uuid UUID [--service-name NAME]\n";
    return 2;
  }

  signal(SIGPIPE, SIG_IGN);
  signal(SIGTERM, handle_signal);
  signal(SIGINT, handle_signal);

  const int listener = socket(AF_INET, SOCK_STREAM, 0);
  if (listener < 0) {
    std::cerr << "socket failed: " << std::strerror(errno) << "\n";
    return 1;
  }
  int reuse = 1;
  setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

  sockaddr_in address {};
  address.sin_family = AF_INET;
  address.sin_port = htons(static_cast<uint16_t>(g_options.port));
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (bind(listener, reinterpret_cast<sockaddr *>(&address),
           sizeof(address)) != 0) {
    std::cerr << "bind failed: " << std::strerror(errno) << "\n";
    close(listener);
    return 1;
  }
  if (listen(listener, 16) != 0) {
    std::cerr << "listen failed: " << std::strerror(errno) << "\n";
    close(listener);
    return 1;
  }
  g_listen_fd = listener;
  std::cout << "Canon G3010 direct eSCL bridge listening on 127.0.0.1:"
            << g_options.port << " for " << g_options.printer_ip << "\n";
  std::cout.flush();

  while (g_running) {
    const int client = accept(listener, nullptr, nullptr);
    if (client < 0) {
      if (errno == EINTR) {
        continue;
      }
      if (g_running) {
        std::cerr << "accept failed: " << std::strerror(errno) << "\n";
      }
      break;
    }
    std::thread(handle_request, client).detach();
  }
  const int fd = g_listen_fd.exchange(-1);
  if (fd >= 0) {
    close(fd);
  }
  return 0;
}
