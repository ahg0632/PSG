#include <string>
#include <vector>
#include <fstream>
#include <iostream>
#include <filesystem>

struct GPObject {
    std::string gpo = "";
    std::string folder_id = "";
    std::string value = "";
    std::string state = "";
    
    void clearGPObject() {
        this->gpo = "";
        this->folder_id = "";
        this->value = "";
        this->state = "";
    }
};


class GPObjectManager {
    private:
    std::vector<GPObject> gpObjects;
    std::ifstream file;

    protected:
    void addGPObject(const GPObject& obj) {
        gpObjects.push_back(obj);
    }
    
    void removeGPObject(const std::string& gpo) {
        gpObjects.erase(std::remove_if(gpObjects.begin(), gpObjects.end(),
        [&gpo](const GPObject& obj) { return obj.gpo == gpo; }), gpObjects.end());
    }

    std::string escapeCSV(const std::string& field) {
        std::string result = "\"";
        for (char c : field) {
            if (c == '"') {
                result += "\"\"";
            } else {
                result += c;
            }
        }
        result += "\"";
        return result;
    }

    public:
    GPObjectManager() = default;
    ~GPObjectManager() {
        if (file.is_open()) {
            file.close();
        }
    }

    void loadFile(const std::string& filename) {
        try {
            file.open(filename);
            if (!file.is_open()) {
                throw std::runtime_error("Could not open file: " + filename);
            }
        } catch(const std::exception& e) {
            std::cerr << e.what() << '\n';
        }
        
    }

    void parseFile() {
        std::string line;
        GPObject obj;

        while (std::getline(file, line)) {

            if(line.find("GPO:") != std::string::npos) {
                do {
                    if (line.find("GPO:") != std::string::npos) {
                        size_t pos = line.find("GPO:") + 4;
                        pos = line.find_first_not_of(" \t", pos);
                        obj.gpo = line.substr(pos);
                    }
                    if (line.find("Folder Id:") != std::string::npos) {
                        size_t pos = line.find("Folder Id:") + 10;
                        pos = line.find_first_not_of(" \t", pos);
                        obj.folder_id = line.substr(pos);
                    }
                    if (line.find("Value:") != std::string::npos) {
                        size_t pos = line.find("Value:") + 6;
                        pos = line.find_first_not_of(" \t", pos);
                        obj.value = line.substr(pos);
                    }
                    if (line.find("State:") != std::string::npos) {
                        size_t pos = line.find("State:") + 6;
                        pos = line.find_first_not_of(" \t", pos);
                        obj.state = line.substr(pos);
                    }
                    std::getline(file, line);
                } while(!line.empty());
                addGPObject(obj);
                obj.clearGPObject();
            }
        }
    }

    void printGPObjects() const {
        for (const auto& obj : gpObjects) {
            std::cout << "GPO: " << obj.gpo << "\n"
                      << "Folder Id: " << obj.folder_id << "\n"
                      << "Value: " << obj.value << "\n"
                      << "State: " << obj.state << "\n\n";
        }
    }

    void exportToCSV(const std::string& filename) {
        std::string csvFilename = 
            "adminTemplate_" +
            std::filesystem::path(filename).stem().string() +
            ".csv";
        std::ofstream csvFile(csvFilename);
        if (!csvFile.is_open()) {
            std::cerr << "Could not open file for writing: " << csvFilename << "\n";
            return;
        }
        // Header
        csvFile << escapeCSV("GPO") << ", "
                << escapeCSV("Folder Id") << ", "
                << escapeCSV("Value") << ", "
                << escapeCSV("State") << "\n";
        // Body
        for (const auto& obj : gpObjects) {
            csvFile << escapeCSV(obj.gpo) << ", "
                    << escapeCSV(obj.folder_id) << ", "
                    << escapeCSV(obj.value) << ", "
                    << escapeCSV(obj.state) << "\n";
        }
        csvFile.close();
    }

    void exportToTXT(const std::string& filename) {
        std::string txtFilename = 
            "adminTemplate_" +
            std::filesystem::path(filename).stem().string() +
            ".txt";
        std::ofstream txtFile(txtFilename);
        if (!txtFile.is_open()) {
            std::cerr << "Could not open file for writing: " << txtFilename << "\n";
            return;
        }
        // Body
        for (const auto& obj : gpObjects) {
            txtFile << (obj.gpo.empty() ? "" : "GPO: " + obj.gpo + "\n");
            txtFile << (obj.folder_id.empty() ? "" : "Folder Id: " + obj.folder_id + "\n");
            txtFile << (obj.value.empty() ? "" : "Value: " + obj.value + "\n");
            txtFile << (obj.state.empty() ? "" : "State: " + obj.state + "\n");
            txtFile << "\n";
        }
        txtFile.close();
    }
};


int main(int argc, char* argv[]) {
    if (argc != 2) {
        std::cerr << "Usage: " << argv[0] << " <filename>\n";
        return 1;
    }
    GPObjectManager manager;
    manager.loadFile(argv[1]);
    manager.parseFile();
    // manager.printGPObjects();
    manager.exportToCSV(argv[1]);
    // manager.exportToTXT(argv[1]);
}